// SPDX-License-Identifier: Apache-2.0
// core/replica: the replication semantics the P3 gate is about
// (AGENTS §2). Everything here is pure computation: real nodes drive
// this module, they do not define it. That is deliberate — the
// property the milestone must prove ("watermarks stay consistent
// across crashes") is a property of this bookkeeping, and real
// processes only make it harder to see.
//
// Semantics follow the reference system as recorded in the report
// (§1.2.5 / §1.2.6-B) and the reference work rules:
//   * replication is follower-pull; this module models the *result*,
//     never the transport;
//   * HW = the minimum LEO across the replica set (leader included);
//   * LRS ≈ ISR: a replica further behind than the lag bound loses its
//     vote but keeps receiving records, and rejoins on catch-up;
//   * there is NO leader epoch. Not a field we left out — a term
//     number would be a different protocol (Raft), and the reference
//     does not have one. Rejoins are resolved by LEO comparison
//     (`resolve_rejoin`), which is why that case needs an explicit
//     project-level rule.

///|
/// A replica's observed progress: the end of its log (LEO). Offsets
/// are exclusive upper bounds, matching core/log's convention.
pub(all) struct ReplicaProgress {
  spu : String
  leo : Int64
} derive(Debug, Eq, Show)

///|
/// What a partition's read path is allowed to expose. The default
/// across the reference system is Uncommitted (report §2.3.1); the
/// switch exists so consumers can ask for the replicated prefix.
pub(all) enum ReadMode {
  Committed
  Uncommitted
} derive(Debug, Eq, Show)

///|
/// The watermark pair every fetch response carries.
pub(all) struct OffsetInfo {
  high_watermark : Int64
  log_end_offset : Int64
} derive(Debug, Eq, Show)

///|
/// Replication bookkeeping failures. All are violations of an
/// invariant, not IO problems: the adapter maps its own errors
/// separately.
pub(all) suberror ReplicaError {
  /// A replica set must be non-empty and contain the leader.
  BadReplicaSet(String)
  /// A reported LEO is negative.
  BadProgress(String)
  /// A role transition that the protocol does not allow.
  IllegalTransition(String)
  /// A read outside the allowed window.
  OutOfRange(String)
}

///|
pub impl Show for ReplicaError with fn output(self, logger) {
  match self {
    BadReplicaSet(msg) => logger.write_string("BadReplicaSet(\{msg})")
    BadProgress(msg) => logger.write_string("BadProgress(\{msg})")
    IllegalTransition(msg) => logger.write_string("IllegalTransition(\{msg})")
    OutOfRange(msg) => logger.write_string("OutOfRange(\{msg})")
  }
}

///|
/// An immutable view of replication progress for one partition: the
/// leader's own LEO plus what each replica has reported. Members are
/// keyed by spu id and hold the *highest* LEO observed — progress
/// never goes backwards within a term, and a stale report arriving
/// late must not drag a watermark down.
pub(all) struct ProgressLedger {
  leader : String
  replicas : Array[ReplicaProgress]
} derive(Debug, Eq, Show)

///|
/// Builds a ledger, rejecting structurally invalid input: an empty
/// replica set, a leader that is not in it, or a negative LEO.
pub fn ProgressLedger::new(
  leader : String,
  replicas : Array[ReplicaProgress],
) -> Result[ProgressLedger, ReplicaError] {
  if replicas.length() == 0 {
    return Err(BadReplicaSet("replica set is empty"))
  }
  let mut has_leader = false
  for r in replicas {
    if r.leo < 0L {
      return Err(BadProgress("replica \{r.spu} reports a negative leo"))
    }
    if r.spu == leader {
      has_leader = true
    }
  }
  if !has_leader {
    return Err(BadReplicaSet("leader \{leader} is not in the replica set"))
  }
  Ok(ProgressLedger::{ leader, replicas })
}

///|
/// Records a replica's reported LEO. Reports are monotonic per
/// replica: an out-of-order (lower) report is ignored rather than
/// applied, because watermarks derived from it would move backwards
/// and a watermark that regresses is a correctness bug, not a
/// transient. Unknown replicas are rejected — the replica set is a
/// control-plane decision, not something a report can widen.
pub fn ProgressLedger::observe(
  self : ProgressLedger,
  spu : String,
  leo : Int64,
) -> Result[Unit, ReplicaError] {
  if leo < 0L {
    return Err(BadProgress("replica \{spu} reports a negative leo"))
  }
  for i in 0..<self.replicas.length() {
    if self.replicas[i].spu == spu {
      if leo > self.replicas[i].leo {
        self.replicas[i] = ReplicaProgress::{ spu, leo }
      }
      return Ok(())
    }
  }
  Err(BadReplicaSet("replica \{spu} is not in this replica set"))
}

///|
/// The leader's own LEO (it is a member like any other).
pub fn ProgressLedger::leader_leo(self : ProgressLedger) -> Int64 {
  for r in self.replicas {
    if r.spu == self.leader {
      return r.leo
    }
  }
  0L
}

///|
/// Appends to the leader's log end. Only the leader writes, so this
/// is the one place LEO grows by local action rather than by report.
pub fn ProgressLedger::advance_leader(
  self : ProgressLedger,
  to : Int64,
) -> Result[Unit, ReplicaError] {
  if to < 0L {
    return Err(BadProgress("leader leo cannot be negative"))
  }
  let current = self.leader_leo()
  if to < current {
    return Err(
      BadProgress("leader leo would move backwards (\{current} -> \{to})"),
    )
  }
  self.observe(self.leader, to)
}

///|
/// The high watermark: the minimum LEO across the replica set, i.e.
/// the prefix every replica is known to hold. Equal to the leader's
/// LEO once every replica has caught up.
pub fn ProgressLedger::high_watermark(self : ProgressLedger) -> Int64 {
  let mut min : Int64? = None
  for r in self.replicas {
    min = match min {
      None => Some(r.leo)
      Some(m) => Some(if r.leo < m { r.leo } else { m })
    }
  }
  match min {
    Some(m) => m
    None => 0L
  }
}

///|
/// The watermark pair handed to clients.
pub fn ProgressLedger::offset_info(self : ProgressLedger) -> OffsetInfo {
  OffsetInfo::{
    high_watermark: self.high_watermark(),
    log_end_offset: self.leader_leo(),
  }
}

///|
/// How far behind the leader a replica may fall and keep its vote.
/// The bound is policy, not mechanism: it is passed in so the
/// control plane (or a test) can tighten or loosen it per topic.
pub(all) struct LrsPolicy {
  max_lag_records : Int64
} derive(Debug, Eq, Show)

///|
/// The default lag bound, in records. Chosen to be generous enough
/// that a briefly busy follower is not evicted, and small enough that
/// a stopped follower stops counting towards the watermark quickly.
pub const DEFAULT_MAX_LAG : Int64 = 1024L

///|
/// The replicas whose LEO is within the lag bound of the leader —
/// the reference's LRS (≈ ISR). Membership carries exactly one
/// privilege: eligibility to be nominated leader. Leaving the set
/// does NOT stop replication; the member keeps receiving records and
/// re-enters the moment it catches up, which is why this is computed
/// rather than stored.
pub fn lrs_members(
  ledger : ProgressLedger,
  policy : LrsPolicy,
) -> Array[String] {
  let leo = ledger.leader_leo()
  let out : Array[String] = []
  for r in ledger.replicas {
    let lag = leo - r.leo
    if lag <= policy.max_lag_records {
      out.push(r.spu)
    }
  }
  out
}

///|
/// Whether a replica currently holds a vote.
pub fn has_vote(
  ledger : ProgressLedger,
  policy : LrsPolicy,
  spu : String,
) -> Bool {
  lrs_members(ledger, policy).contains(spu)
}

///|
/// The exclusive offset a read may reach under the given mode:
/// Uncommitted reads everything the leader holds, Committed only the
/// replicated prefix.
pub fn read_limit(info : OffsetInfo, mode : ReadMode) -> Int64 {
  match mode {
    Committed => info.high_watermark
    Uncommitted => info.log_end_offset
  }
}

///|
/// Validates a read window against the mode's limit. Fetching at
/// exactly the limit is legal and returns nothing (the caller is
/// caught up); beyond it is a structured refusal rather than an
/// empty read, so a consumer never mistakes "not replicated yet" for
/// "no data".
pub fn check_read(
  info : OffsetInfo,
  mode : ReadMode,
  from : Int64,
  max_records : Int,
) -> Result[Unit, ReplicaError] {
  if from < 0L || max_records < 0 {
    return Err(OutOfRange("negative offset or count"))
  }
  let limit = read_limit(info, mode)
  if from > limit {
    return Err(OutOfRange("read at \{from} exceeds \{mode} limit \{limit}"))
  }
  Ok(())
}

///|
/// A replica's role. There is deliberately no term/epoch field: the
/// reference system has none on the data plane, and inventing one
/// would change what "rejoin" means.
pub(all) enum Role {
  Follower
  Candidate
  Leader
} derive(Debug, Eq, Show)

///|
/// A replica's control state: its role and the leader it believes in.
pub(all) struct ReplicaState {
  spu : String
  role : Role
  leader : String?
} derive(Debug, Eq, Show)

///|
pub fn ReplicaState::follower(spu : String, leader : String) -> ReplicaState {
  ReplicaState::{ spu, role: Follower, leader: Some(leader) }
}

///|
/// A nomination from the control plane. The candidate must be in the
/// LRS for the partition — checked by the control plane against the
/// ledger — and holds no authority until it has promoted itself.
/// Modelled as a value so "who was nominated for what" is data, not
/// a call.
pub(all) struct Nomination {
  partition_leader : String
  candidate : String
} derive(Debug, Eq, Show)

///|
/// Promotes a nominated replica. Two-phase in the reference (SC
/// nominates, the candidate promotes itself and confirms); this is
/// the candidate's half, and it refuses anything it was not offered:
/// a replica that promotes itself without a nomination for itself is
/// split brain, not initiative.
pub fn promote(
  state : ReplicaState,
  nomination : Nomination,
) -> Result[ReplicaState, ReplicaError] {
  if nomination.candidate != state.spu {
    return Err(
      IllegalTransition(
        "\{state.spu} was not nominated (candidate is \{nomination.candidate})",
      ),
    )
  }
  if state.role is Leader {
    return Err(IllegalTransition("\{state.spu} is already leader"))
  }
  Ok(ReplicaState::{ spu: state.spu, role: Leader, leader: Some(state.spu) })
}

///|
/// A replica that learns of a different leader steps down, whoever it
/// was: the returning old leader self-demotes rather than contesting
/// (reference §1.2.6-B). Applied to a follower it is a no-op that
/// still records the leader it should be pulling from.
pub fn follow(state : ReplicaState, leader : String) -> ReplicaState {
  if leader == state.spu {
    // a leader does not follow itself; this is a caller bug we
    // surface rather than silently accept
    return state
  }
  ReplicaState::{ spu: state.spu, role: Follower, leader: Some(leader) }
}

///|
/// What a rejoining replica must do before it may serve as a source:
/// catch up, or truncate a prefix the new leader does not have.
pub(all) enum RejoinPlan {
  /// Local LEO is at or behind the leader: replicate forward.
  CatchUp(Int64)
  /// Local LEO runs past the leader's: the tail was never replicated
  /// (it was written by a leader that lost the partition), so it must
  /// go. The reference system defines no epoch-based truncation to
  /// fall back on, so this project defines the rule here: the new
  /// leader's LEO is the only authority, and the discard is reported.
  TruncateTo(Int64)
} derive(Debug, Eq, Show)

///|
/// Decides how a replica rejoins. This is the case the reference
/// leaves open (no leader epoch ⇒ no epoch truncation), so the rule
/// is ours and is stated once, here: **the leader's LEO wins**.
pub fn resolve_rejoin(local_leo : Int64, leader_leo : Int64) -> RejoinPlan {
  if local_leo > leader_leo {
    TruncateTo(leader_leo)
  } else {
    CatchUp(local_leo)
  }
}

///|
/// Picks the replica the control plane should nominate after the
/// leader is gone: the one furthest along, since it loses the least
/// data by promoting. Only replicas with a vote are eligible —
/// a lagging replica is not a candidate no matter how willing it is.
/// Returns None when no eligible replica exists, which the control
/// plane turns into Offline (reference §1.2.6-B).
pub fn elect_candidate(
  ledger : ProgressLedger,
  policy : LrsPolicy,
  offline_leader : String,
) -> String? {
  let eligible = lrs_members(ledger, policy)
  let mut best : String? = None
  let mut best_leo : Int64 = -1L
  for r in ledger.replicas {
    if r.spu == offline_leader {
      continue
    }
    if !eligible.contains(r.spu) {
      continue
    }
    if r.leo > best_leo {
      best = Some(r.spu)
      best_leo = r.leo
    }
  }
  best
}

///|
/// The number of records a replica is missing relative to the leader.
pub fn lag_of(ledger : ProgressLedger, spu : String) -> Int64? {
  let leo = ledger.leader_leo()
  for r in ledger.replicas {
    if r.spu == spu {
      return Some(leo - r.leo)
    }
  }
  None
}
