// Blackbox tests for moonflux/core/replica: the replication semantics
// behind the P3 gate. These are the assertions the fault-injection
// script can only demonstrate noisily — here they are exact.

///|
fn progress(spu : String, leo : Int64) -> @replica.ReplicaProgress {
  @replica.ReplicaProgress::{ spu, leo, }
}

///|
fn ledger(
  leader : String,
  replicas : Array[@replica.ReplicaProgress],
) -> @replica.ProgressLedger {
  match @replica.ProgressLedger::new(leader, replicas) {
    Ok(l) => l
    Err(e) => abort("ledger: \{e}")
  }
}

///|
fn policy(max_lag : Int64) -> @replica.LrsPolicy {
  @replica.LrsPolicy::{ max_lag_records: max_lag, }
}

///|
test "high watermark is the minimum leo across the replica set" {
  // the leader is a member like any other: if the leader's own log end
  // were ignored, HW could exceed what is actually stored
  let l = ledger("a", [progress("a", 10L), progress("b", 7L), progress("c", 9L)])
  assert_eq(l.high_watermark(), 7L)
  assert_eq(l.leader_leo(), 10L)
  let info = l.offset_info()
  assert_eq(info.high_watermark, 7L)
  assert_eq(info.log_end_offset, 10L)
}

///|
test "a caught-up replica set has hw == leo" {
  let l = ledger("a", [progress("a", 42L), progress("b", 42L)])
  assert_eq(l.high_watermark(), 42L)
  assert_eq(l.high_watermark(), l.leader_leo())
}

///|
test "watermarks never move backwards when a stale report arrives" {
  let l = ledger("a", [progress("a", 10L), progress("b", 10L)])
  assert_eq(l.high_watermark(), 10L)
  // b reports an older position (reordered/late packet)
  match l.observe("b", 4L) {
    Ok(_) => ()
    Err(e) => abort("observe: \{e}")
  }
  assert_eq(l.high_watermark(), 10L)
  // and the leader cannot walk its own log end back either
  match l.advance_leader(9L) {
    Err(BadProgress(_)) => ()
    Ok(_) => abort("leader leo must not regress")
    Err(e) => abort("expected BadProgress, got \{e}")
  }
}

///|
test "progress advances only forward, per replica" {
  let l = ledger("a", [progress("a", 1L), progress("b", 1L)])
  assert_eq(l.high_watermark(), 1L)
  let _ = l.advance_leader(5L)
  assert_eq(l.leader_leo(), 5L)
  // hw stays pinned by the slowest replica
  assert_eq(l.high_watermark(), 1L)
  let _ = l.observe("b", 3L)
  assert_eq(l.high_watermark(), 3L)
  let _ = l.observe("b", 5L)
  assert_eq(l.high_watermark(), 5L)
}

///|
test "unknown replicas cannot widen the replica set" {
  let l = ledger("a", [progress("a", 1L)])
  match l.observe("intruder", 100L) {
    Err(BadReplicaSet(_)) => ()
    Ok(_) => abort("an unknown replica must be rejected")
    Err(e) => abort("expected BadReplicaSet, got \{e}")
  }
}

///|
test "a ledger refuses a leader outside the replica set" {
  assert_true(
    @replica.ProgressLedger::new("ghost", [progress("a", 1L)])
    is Err(BadReplicaSet(_)),
  )
  assert_true(@replica.ProgressLedger::new("a", []) is Err(BadReplicaSet(_)))
  assert_true(
    @replica.ProgressLedger::new("a", [progress("a", -1L)])
    is Err(BadProgress(_)),
  )
}

///|
test "lrs membership follows the lag bound and rejoins on catch-up" {
  let p = policy(5L)
  let l = ledger("a", [
    progress("a", 100L),
    progress("b", 98L),
    progress("c", 80L),
  ])
  // c is 20 behind: out of the LRS, but still a replica
  assert_eq(@replica.lrs_members(l, p), ["a", "b"])
  assert_true(@replica.has_vote(l, p, "b"))
  assert_true(!@replica.has_vote(l, p, "c"))
  // lagging does not remove it from the set: it keeps receiving records
  assert_eq(@replica.lag_of(l, "c"), Some(20L))
  // it catches up and re-enters without any external bookkeeping
  let _ = l.observe("c", 95L)
  assert_true(@replica.has_vote(l, p, "c"))
  assert_eq(@replica.lrs_members(l, p).length(), 3)
}

///|
test "read mode clamps at the watermark or the log end" {
  let l = ledger("a", [progress("a", 10L), progress("b", 4L)])
  let info = l.offset_info()
  assert_eq(@replica.read_limit(info, Uncommitted), 10L)
  assert_eq(@replica.read_limit(info, Committed), 4L)
  // reading exactly at the limit is legal and empty; past it is not
  assert_true(@replica.check_read(info, Committed, 4L, 10) is Ok(_))
  assert_true(
    @replica.check_read(info, Committed, 5L, 10) is Err(OutOfRange(_)),
  )
  // the same offset is fine once the replica catches up
  assert_true(@replica.check_read(info, Uncommitted, 5L, 10) is Ok(_))
}

///|
test "nomination is required to become leader" {
  let follower = @replica.ReplicaState::follower("b", "a")
  // self-promotion without a nomination is refused: no split brain
  let bogus = @replica.Nomination::{ partition_leader: "a", candidate: "c", }
  assert_true(@replica.promote(follower, bogus) is Err(IllegalTransition(_)))
  let mine = @replica.Nomination::{ partition_leader: "a", candidate: "b", }
  let leader = match @replica.promote(follower, mine) {
    Ok(s) => s
    Err(e) => abort("promote: \{e}")
  }
  assert_true(leader.role is Leader)
  assert_eq(leader.leader, Some("b"))
  // promoting an existing leader again is a protocol error
  assert_true(@replica.promote(leader, mine) is Err(IllegalTransition(_)))
}

///|
test "a returning leader steps down to follower" {
  let leader = @replica.ReplicaState::{
    spu: "a",
    role: Leader,
    leader: Some("a"),
  }
  let demoted = @replica.follow(leader, "b")
  assert_true(demoted.role is Follower)
  assert_eq(demoted.leader, Some("b"))
}

///|
test "the new leader's leo is the only authority on rejoin" {
  // local is behind: nothing to discard, replicate forward
  assert_true(@replica.resolve_rejoin(5L, 9L) is CatchUp(5L))
  assert_true(@replica.resolve_rejoin(9L, 9L) is CatchUp(9L))
  // local runs past the leader: the tail was never replicated, and
  // with no epoch to compare there is nothing to merge — it goes
  assert_true(@replica.resolve_rejoin(12L, 9L) is TruncateTo(9L))
}

///|
test "the control plane nominates the least lagging eligible replica" {
  let p = policy(5L)
  let l = ledger("a", [
    progress("a", 100L),
    progress("b", 99L),
    progress("c", 60L),
  ])
  // a is gone; b is furthest along and eligible
  assert_eq(@replica.elect_candidate(l, p, "a"), Some("b"))
  // the group moved on without b: everyone who remains is now too
  // far behind to be trusted with the partition
  let _ = l.advance_leader(200L)
  assert_eq(@replica.elect_candidate(l, p, "a"), None)
  // b catches up and becomes the candidate again — no bookkeeping
  // beyond the lag bound brought it back
  let _ = l.observe("b", 199L)
  assert_eq(@replica.elect_candidate(l, p, "a"), Some("b"))
}

///|
test "the offline leader is never its own candidate" {
  let p = policy(1000L)
  let l = ledger("a", [progress("a", 500L), progress("b", 10L)])
  // even though a is furthest along, it is the one that vanished
  assert_eq(@replica.elect_candidate(l, p, "a"), Some("b"))
}
