// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for apps/cli's node table — the control plane's
// liveness bookkeeping. The E2E gate proves it over real processes;
// these prove the transitions are exactly right, including the ones
// that are hard to time reliably in a shell script.

///|
fn rec(id : String, role : @client.NodeRole, leo : Int64) -> @client.NodeRecord {
  @client.NodeRecord::{ id, role, address: "127.0.0.1:1", leo }
}

///|
test "first contact registers, later contact updates the same entry" {
  let table = NodeTable::new(1000)
  assert_true(table.observe(rec("spu-a", Spu, 0L), 100L))
  assert_eq(table.entries.length(), 1)
  assert_true(table.observe(rec("spu-a", Spu, 5L), 200L))
  assert_eq(table.entries.length(), 1)
  assert_eq(table.entries[0].record.leo, 5L)
  assert_eq(table.entries[0].last_seen_ms, 200L)
  assert_true(table.entries[0].online)
}

///|
test "a node goes offline only after the timeout, and only once" {
  let table = NodeTable::new(1000)
  let _ = table.observe(rec("spu-a", Spu, 0L), 100L)
  // within the window: still online
  assert_eq(table.sweep(1099L).length(), 0)
  assert_true(table.entries[0].online)
  // past the window: one transition, reported once
  assert_eq(table.sweep(1101L), ["spu-a"])
  assert_true(!table.entries[0].online)
  // and never again while it stays silent — level-triggered, not a
  // per-tick event stream
  assert_eq(table.sweep(5000L).length(), 0)
  assert_eq(table.sweep(9000L).length(), 0)
}

///|
test "a heartbeat revives an offline node" {
  let table = NodeTable::new(1000)
  let _ = table.observe(rec("spu-a", Spu, 0L), 100L)
  assert_eq(table.sweep(1101L).length(), 1)
  assert_true(!table.entries[0].online)
  // a heartbeat is enough: liveness is derived from the last report,
  // so there is no separate "come back" message to get wrong
  let _ = table.observe(rec("spu-a", Spu, 12L), 1200L)
  assert_true(table.entries[0].online)
  assert_eq(table.snapshot().length(), 1)
  // and the revival is not reported as another offline transition:
  // the clock restarted from the heartbeat, not from the old report
  assert_eq(table.sweep(2100L).length(), 0)
  assert_true(table.entries[0].online)
}

///|
test "the snapshot lists online nodes, id-sorted" {
  let table = NodeTable::new(1000)
  let _ = table.observe(rec("spu-c", Spu, 0L), 10L)
  let _ = table.observe(rec("spu-a", Spu, 0L), 10L)
  let _ = table.observe(rec("sc-1", Sc, 0L), 10L)
  assert_eq(table.snapshot().map(fn(r) { r.id }), ["sc-1", "spu-a", "spu-c"])
  // a dead node drops out of the snapshot but stays in the table, so
  // its identity is remembered if it comes back
  let _ = table.sweep(5000L)
  assert_eq(table.snapshot().length(), 0)
  assert_eq(table.entries.length(), 3)
}
