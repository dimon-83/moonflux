#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * Resolves host (name or numeric) and returns a connected socket,
 * trying each address in order. Returns fd or -errno.
 */
int mf_net_connect(const uint8_t *host, int host_len, int port) {
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

int mf_net_accept(int fd) { return accept(fd, NULL, NULL); }

/*
 * Accept with a deadline. SO_RCVTIMEO does NOT cover accept() on
 * macOS/BSD (it only covers recv), so a timeout there is honoured
 * here with poll() instead of a socket option: wait for readability,
 * then accept. ms <= 0 means "block forever".
 */
int mf_net_accept_timeout(int fd, int ms) {
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

int mf_net_send(int fd, const uint8_t *buf, int len) {
  return (int)send(fd, buf, len, 0);
}

int mf_net_recv(int fd, uint8_t *buf, int len) {
  int n = (int)recv(fd, buf, len, 0);
  if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
    return -MF_NET_TIMEOUT;
  }
  return n;
}

int mf_net_close(int fd) { return close(fd); }

int mf_net_socketpair(int *pair) {
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -errno;
  pair[0] = fds[0];
  pair[1] = fds[1];
  return 0;
}
