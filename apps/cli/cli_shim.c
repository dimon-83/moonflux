// SPDX-License-Identifier: Apache-2.0
// apps/cli native shim: output flushing.
//
// A node is a long-lived process whose stdout is usually redirected
// to a log. C stdio block-buffers in that case, so nothing a running
// node prints is readable until it exits — and a node killed by a
// signal never flushes at all. Cluster operations (who registered,
// who went offline, which leader was elected) are exactly the lines
// an operator needs *while* the process runs, so the CLI flushes
// after each note.
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <sys/wait.h>
#include <string.h>
#include <fcntl.h>

void mf_cli_flush(void) {
  fflush(stdout);
  fflush(stderr);
}

/*
 * Writes a line to stderr and flushes. Used for diagnostics that must
 * not contaminate stdout: `consume` prints records there and callers
 * parse them by column, so a watermark note has to travel on the
 * other stream.
 */
void mf_cli_eprint(const uint8_t *buf, int len) {
  if (len > 0) {
    fwrite(buf, 1, (size_t)len, stderr);
  }
  fputc('\n', stderr);
  fflush(stderr);
}

/*
 * The process id, for callers that need a unique default (a consumer
 * group member without an explicit --member). Two CLI processes that
 * shared a member id would look like one member reading twice, which
 * is worse than a slightly ugly name.
 */
int32_t mf_cli_pid(void) {
  return (int32_t)getpid();
}

/*
 * Sleeps for the given number of milliseconds. Used by the group
 * member's loop, which polls for work and must not spin a core while
 * waiting.
 */
void mf_cli_sleep_ms(int32_t ms) {
  if (ms > 0) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
  }
}

/*
 * A monotonic microsecond clock, for the benchmark's latency
 * histograms. The environment's clock is millisecond-resolution, and a
 * local round trip is not: a histogram whose p50 rounds to 0 is not a
 * baseline. Monotonic rather than wall time on purpose — a benchmark
 * measures intervals, and intervals must not jump when NTP corrects
 * the wall clock.
 */
int64_t mf_cli_now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/*
 * The host name of a RUNNER (P37-2). The platform's run table answers "what is
 * running, where" — and pid plus host are the parts of "where" a run can
 * honestly supply: a run is not a node, it accepts no connections, so it has no
 * address of its own. `mf_cli_hostname` writes into a caller buffer and returns
 * the length it wrote (0 when it could not find out), so the caller decides what
 * an unknown host looks like. (`mf_cli_pid` already existed above.)
 */
int mf_cli_hostname(uint8_t *buf, int len) {
  if (len <= 0) {
    return 0;
  }
  if (gethostname((char *)buf, (size_t)len) != 0) {
    return 0;
  }
  /* gethostname does not promise NUL termination when it truncates */
  buf[len - 1] = 0;
  int n = 0;
  while (n < len && buf[n] != 0) {
    n++;
  }
  return n;
}

// ---------------------------------------------------------------------
// Signal handling and child-process supervision, for the runner.
//
// A runner supervises child `pipeline run` processes: it spawns them, reaps
// them (non-blocking, from its own event loop), restarts them by policy, and
// on its own SIGTERM forwards the signal so each child stops gracefully. The
// SIGTERM handler is deliberately minimal — it sets a flag and nothing else —
// because a signal handler may only do async-signal-safe work.

static volatile sig_atomic_t g_term_requested = 0;

static void mf_term_handler(int sig) {
  (void)sig;
  g_term_requested = 1;
}

void mf_cli_install_term_handler(void) {
  struct sigaction sa;
  sa.sa_handler = mf_term_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0; /* no SA_RESTART: a poll/sleep returns, the loop notices */
  sigaction(SIGTERM, &sa, 0);
  sigaction(SIGINT, &sa, 0);
}

int mf_cli_term_requested(void) { return g_term_requested; }

/* Spawns `prog` with the flattened argv (strings separated by NUL, the list
 * ending with an empty entry, i.e. two consecutive NULs). Returns the child
 * pid, or -1 on failure. The child is exec'd directly — no shell — so a task
 * name or data dir never reaches a shell's interpretation. */
/* Shared by the two spawn entry points: argv_flat is strings separated by NUL
 * ending with an empty entry, and stderr_path (may be NULL) is where the child's
 * standard error goes. Redirecting stderr is how a supervised task's diagnostics
 * reach the operator: the runner keeps them per task, and `task logs` can then
 * show a task's run-log events AND what the process itself said. */
static int32_t mf_cli_spawn_common(const uint8_t *prog, const uint8_t *argv_flat,
                                   const uint8_t *stderr_path) {
  pid_t pid = fork();
  if (pid < 0) {
    return -1;
  }
  if (pid == 0) {
    if (stderr_path != NULL && stderr_path[0] != '\0') {
      int fd = open((const char *)stderr_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (fd >= 0) {
        dup2(fd, 2);
        if (fd != 2) {
          close(fd);
        }
      }
    }
    char *argv[16];
    int n = 0;
    const char *p = (const char *)argv_flat;
    while (n < 15) {
      argv[n++] = (char *)p;
      const char *e = p;
      while (*e != '\0') e++;
      p = e + 1;
      if (*p == '\0') { /* the empty entry terminates the list */
        argv[n] = NULL;
        break;
      }
    }
    argv[n] = NULL;
    execv((const char *)prog, argv);
    _exit(127); /* only reachable if exec failed */
  }
  return (int32_t)pid;
}

int32_t mf_cli_spawn(const uint8_t *prog, const uint8_t *argv_flat) {
  return mf_cli_spawn_common(prog, argv_flat, NULL);
}

int32_t mf_cli_spawn_to(const uint8_t *prog, const uint8_t *argv_flat,
                        const uint8_t *stderr_path) {
  return mf_cli_spawn_common(prog, argv_flat, stderr_path);
}

int mf_cli_kill(int32_t pid, int sig) { return kill((pid_t)pid, sig); }

/* Non-blocking reap. Returns 0 while the child still runs, -1 on error, and
 * (exit_code + 1) once it has exited (so "exited with 0" is 1, which the caller
 * subtracts). Signal deaths come back as 128 + signo, like a shell. */
int64_t mf_cli_reap(int32_t pid) {
  int status;
  pid_t r = waitpid((pid_t)pid, &status, WNOHANG);
  if (r == 0) {
    return 0;
  }
  if (r < 0) {
    return -1;
  }
  int code;
  if (WIFEXITED(status)) {
    code = WEXITSTATUS(status);
  } else if (WIFSIGNALED(status)) {
    code = 128 + WTERMSIG(status);
  } else {
    code = 1;
  }
  return (int64_t)code + 1;
}
