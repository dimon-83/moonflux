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
#include <stdio.h>

void mf_cli_flush(void) {
  fflush(stdout);
  fflush(stderr);
}
