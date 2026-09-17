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
