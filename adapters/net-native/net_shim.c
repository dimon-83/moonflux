#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * SIGPIPE, ignored once per process.
 *
 * A write to a peer that has gone away raises SIGPIPE, whose default
 * action is to kill the process — so a server whose client disconnects at
 * the wrong moment dies with it. The syscall is supposed to report the
 * fact (EPIPE) instead, and ignoring the signal is what lets it: the
 * write then fails and the connection is closed, which is the behaviour
 * every one of these call sites already handles.
 *
 * This was a real crash (exit code 141) on the control plane: a peer that
 * connected and then vanished took the whole process down with it. The
 * disposition is process-wide, so setting it once covers TLS writes too
 * (SSL_write calls send() internally).
 */
static void mf_net_ignore_sigpipe(void) {
  static int done = 0;
  if (!done) {
    signal(SIGPIPE, SIG_IGN);
    done = 1;
  }
}

/*
 * Resolves host (name or numeric) and returns a connected socket,
 * trying each address in order. Returns fd or -errno.
 */
int mf_net_connect(const uint8_t *host, int host_len, int port) {
  mf_net_ignore_sigpipe();
  char hostz[512];
  if (host_len < 0 || host_len >= 512) return -EINVAL;
  memcpy(hostz, host, host_len);
  hostz[host_len] = 0;

  char portz[8];
  snprintf(portz, sizeof(portz), "%d", port);

  struct addrinfo hints, *res = NULL, *rp;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  int gai = getaddrinfo(hostz, portz, &hints, &res);
  if (gai != 0) return -ECONNREFUSED;

  int fd = -1;
  for (rp = res; rp != NULL; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) { return errno ? -errno : -ECONNREFUSED; }
  return fd;
}

int mf_net_bind_listen(const uint8_t *host, int host_len, int port) {
  mf_net_ignore_sigpipe();
  char hostz[512];
  if (host_len < 0 || host_len >= 512) return -EINVAL;
  memcpy(hostz, host, host_len);
  hostz[host_len] = 0;

  struct addrinfo hints, *res = NULL, *rp;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  char portz[8];
  snprintf(portz, sizeof(portz), "%d", port);
  int gai = getaddrinfo(hostz[0] ? hostz : NULL, portz, &hints, &res);
  if (gai != 0) return -EINVAL;

  int fd = -1;
  for (rp = res; rp != NULL; rp = rp->ai_next) {
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, rp->ai_addr, rp->ai_addrlen) == 0 && listen(fd, 16) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) return -errno;
  return fd;
}

int mf_net_getsockport(int fd) {
  struct sockaddr_storage ss;
  socklen_t len = sizeof(ss);
  if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) return -errno;
  if (ss.ss_family == AF_INET) {
    return ntohs(((struct sockaddr_in *)&ss)->sin_port);
  }
  if (ss.ss_family == AF_INET6) {
    return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
  }
  return -EINVAL;
}

/*
 * Timeouts are reported with a dedicated code rather than errno, so
 * the MoonBit side can tell "nothing to accept yet" from a real
 * failure without knowing platform errno values.
 */
#define MF_NET_TIMEOUT 9999

int mf_net_accept(int fd) {
  int n = accept(fd, NULL, NULL);
  if (n < 0) return -errno;
  return n;
}

/*
 * Accept with a deadline. SO_RCVTIMEO does NOT cover accept() on
 * macOS/BSD (it only covers recv), so a timeout there is honoured
 * here with poll() instead of a socket option: wait for readability,
 * then accept. ms <= 0 means "block forever".
 */
int mf_net_accept_timeout(int fd, int ms) {
  mf_net_ignore_sigpipe();
  if (ms <= 0) {
    return mf_net_accept(fd);
  }
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int rc = poll(&pfd, 1, ms);
  if (rc == 0) {
    return -MF_NET_TIMEOUT;
  }
  if (rc < 0) {
    return -errno;
  }
  return mf_net_accept(fd);
}

/*
 * Sets SO_RCVTIMEO (which also makes accept() time out) in
 * milliseconds; 0 clears it. Returns 0 or -errno.
 */
int mf_net_set_recv_timeout(int fd, int ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
    return -errno;
  }
  return 0;
}

/*
 * Non-blocking mode and readiness polling: the pieces a single-threaded
 * server needs to serve several connections without threads. `recv` on
 * a non-blocking fd returns -MF_NET_WOULD_BLOCK when there is nothing
 * to read right now — distinct from 0 (peer closed) and from an error.
 */
#define MF_NET_WOULD_BLOCK 9998

int mf_net_set_nonblocking(int fd, int enabled) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -errno;
  if (enabled) {
    flags |= O_NONBLOCK;
  } else {
    flags &= ~O_NONBLOCK;
  }
  if (fcntl(fd, F_SETFL, flags) < 0) return -errno;
  return 0;
}

/*
 * Reads what is available. Returns the byte count, -MF_NET_WOULD_BLOCK
 * when there is nothing, or **-errno** for a real failure.
 *
 * The -errno convention is not decoration: returning a bare -1 makes
 * every failure look like EPERM to the MoonBit side, which decodes -n as
 * the errno. That is how "connection reset by peer" (54) was reported as
 * "Io(errno=1)" — a message that names the wrong cause and sends the
 * reader looking for a permission problem that does not exist.
 */
int mf_net_recv_some(int fd, uint8_t *buf, int len) {
  int n = (int)recv(fd, buf, len, 0);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -MF_NET_WOULD_BLOCK;
    return -errno;
  }
  return n;
}

/*
 * Polls `count` fds for readability. `fds` is an int array; writes 1
 * into `ready[i]` for each readable fd. Returns the number readable, or
 * -errno. A timeout of 0 polls without waiting.
 */
int mf_net_poll_readable(const int *fds, int count, int timeout_ms,
                         int *ready) {
  struct pollfd pfds[128];
  if (count < 0 || count > 128) return -EINVAL;
  for (int i = 0; i < count; i++) {
    pfds[i].fd = fds[i];
    pfds[i].events = POLLIN;
    pfds[i].revents = 0;
    ready[i] = 0;
  }
  int rc = poll(pfds, (nfds_t)count, timeout_ms);
  if (rc < 0) return -errno;
  int hits = 0;
  for (int i = 0; i < count; i++) {
    if (pfds[i].revents & (POLLIN | POLLHUP | POLLERR)) {
      ready[i] = 1;
      hits++;
    }
  }
  return hits;
}

/*
 * Polls for *writability* (P12): a TLS handshake that answered
 * SSL_ERROR_WANT_WRITE is waiting for buffer space, not for data, and
 * polling its socket for readability would spin or sleep forever.
 */
int mf_net_poll_writable(const int *fds, int count, int timeout_ms,
                         int *ready) {
  struct pollfd pfds[128];
  if (count < 0 || count > 128) return -EINVAL;
  for (int i = 0; i < count; i++) {
    pfds[i].fd = fds[i];
    pfds[i].events = POLLOUT;
    pfds[i].revents = 0;
    ready[i] = 0;
  }
  int rc = poll(pfds, (nfds_t)count, timeout_ms);
  if (rc < 0) return -errno;
  int hits = 0;
  for (int i = 0; i < count; i++) {
    if (pfds[i].revents & (POLLOUT | POLLHUP | POLLERR)) {
      ready[i] = 1;
      hits++;
    }
  }
  return hits;
}

int mf_net_send(int fd, const uint8_t *buf, int len) {
  int n = (int)send(fd, buf, len, 0);
  if (n < 0) return -errno;
  return n;
}

/* Reads a whole buffer; same conventions as mf_net_recv_some, with the
 * socket's receive timeout reported as -MF_NET_TIMEOUT. */
int mf_net_recv(int fd, uint8_t *buf, int len) {
  int n = (int)recv(fd, buf, len, 0);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -MF_NET_TIMEOUT;
    return -errno;
  }
  return n;
}

int mf_net_close(int fd) { return close(fd); }

int mf_net_socketpair(int *pair) {
  mf_net_ignore_sigpipe();
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -errno;
  pair[0] = fds[0];
  pair[1] = fds[1];
  return 0;
}

/* Writes what the socket accepts; -MF_NET_WOULD_BLOCK when its window is
 * full, -errno for a real failure (same reason as mf_net_recv_some). */
int mf_net_send_some(int fd, const uint8_t *buf, int len) {
  int n = (int)send(fd, buf, len, 0);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -MF_NET_WOULD_BLOCK;
    return -errno;
  }
  return n;
}

/*
 * The text for an errno, for error messages built on the MoonBit side.
 * Without it every socket failure prints as a number, and
 * "Io(errno=54, op=recv)" makes the reader look up 54 instead of reading
 * "connection reset by peer".
 */
void mf_net_strerror(int code, uint8_t *buf, int len) {
  const char *text = strerror(code);
  if (text == NULL) text = "unknown error";
  int n = (int)strlen(text);
  if (n >= len) n = len - 1;
  if (n < 0) n = 0;
  memcpy(buf, text, (size_t)n);
  buf[n] = 0;
}
