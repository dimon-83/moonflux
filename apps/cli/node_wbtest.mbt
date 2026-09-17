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
  assert_true(table.observe(rec("spu-a", Spu, 0L), [], 100L))
  assert_eq(table.entries.length(), 1)
  assert_true(table.observe(rec("spu-a", Spu, 5L), [], 200L))
  assert_eq(table.entries.length(), 1)
  assert_eq(table.entries[0].record.leo, 5L)
  assert_eq(table.entries[0].last_seen_ms, 200L)
  assert_true(table.entries[0].online)
}

///|
test "a node goes offline only after the timeout, and only once" {
  let table = NodeTable::new(1000)
  let _ = table.observe(rec("spu-a", Spu, 0L), [], 100L)
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
  let _ = table.observe(rec("spu-a", Spu, 0L), [], 100L)
  assert_eq(table.sweep(1101L).length(), 1)
  assert_true(!table.entries[0].online)
  // a heartbeat is enough: liveness is derived from the last report,
  // so there is no separate "come back" message to get wrong
  let _ = table.observe(rec("spu-a", Spu, 12L), [], 1200L)
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
  let _ = table.observe(rec("spu-c", Spu, 0L), [], 10L)
  let _ = table.observe(rec("spu-a", Spu, 0L), [], 10L)
  let _ = table.observe(rec("sc-1", Sc, 0L), [], 10L)
  assert_eq(table.snapshot().map(fn(r) { r.id }), ["sc-1", "spu-a", "spu-c"])
  // a dead node drops out of the snapshot but stays in the table, so
  // its identity is remembered if it comes back
  let _ = table.sweep(5000L)
  assert_eq(table.snapshot().length(), 0)
  assert_eq(table.entries.length(), 3)
}

///|
test "placement state remembers assignments and pending offers" {
  let state = PlacementState::new("/tmp/moonflux-placement-test-nonexistent")
  assert_eq(state.state.partitions.length(), 0)
  // a fresh control plane knows nothing; the view answers "nobody
  // leads" rather than inventing a leader
  let view = state.view("events", 0)
  assert_eq(view.leader, "")
  assert_eq(view.replicas.length(), 0)
  assert_eq(view.nominated, "")
}

///|
test "a promotion without a nomination is refused" {
  let state = PlacementState::new("/tmp/moonflux-placement-test-nonexistent")
  // no election was ever offered: a node claiming the partition is
  // promoting itself, which is exactly what must not be accepted
  match state.confirm("events", 0, "127.0.0.1:2") {
    Err(msg) => assert_true(msg.contains("without a nomination"))
    Ok(_) => abort("an unrequested promotion must be refused")
  }
}

///|
test "a nomination offered to one node cannot be claimed by another" {
  let state = PlacementState::new("/tmp/moonflux-placement-test-nonexistent")
  state.set_nomination("events[0]", "127.0.0.1:2")
  assert_eq(state.nomination_of("events[0]"), Some("127.0.0.1:2"))
  match state.confirm("events", 0, "127.0.0.1:3") {
    Err(msg) => assert_true(msg.contains("was offered to"))
    Ok(_) => abort("a stranger must not claim the offer")
  }
  // the right node is accepted, and the offer is consumed
  match state.confirm("events", 0, "127.0.0.1:2") {
    Ok(_) => ()
    Err(e) => abort("the nominated node should be accepted: \{e}")
  }
  assert_eq(state.nomination_of("events[0]"), None)
}

///|
test "the ledger yardstick is the best surviving copy" {
  // this mirrors what elect_fallen_leaders does: measure lag against
  // the furthest-along replica, not against the vanished leader
  let progress : Array[@replica.ReplicaProgress] = [
    @replica.ReplicaProgress::{ spu: "a", leo: 3L },
    @replica.ReplicaProgress::{ spu: "b", leo: 1200L },
  ]
  let ledger = match @replica.ProgressLedger::new("b", progress) {
    Ok(ledger) => ledger
    Err(e) => abort("ledger: \{e}")
  }
  let policy = @replica.LrsPolicy::{ max_lag_records: @replica.DEFAULT_MAX_LAG }
  // asking with a as the reference would call b "caught up" and
  // measure nothing; with b as the yardstick, a is far behind
  assert_eq(@replica.lag_of(ledger, "a"), Some(1197L))
  assert_true(!@replica.has_vote(ledger, policy, "a"))
  // and b — the yardstick itself — is eligible by definition
  assert_true(@replica.has_vote(ledger, policy, "b"))
}
