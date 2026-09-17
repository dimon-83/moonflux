// SPDX-License-Identifier: Apache-2.0
// Consumer groups, kernel side (P9).
//
// Three ideas, and everything else follows from them:
//
//   * **membership is derived from reports**, exactly like node
//     liveness: a member is present because it spoke recently, and a
//     silent one leaves without anyone declaring it gone;
//   * **the epoch is the membership generation**: it moves whenever the
//     member set does, and a commit carries it. A member that lost its
//     partitions cannot overwrite its successor's progress, because its
//     epoch is no longer current;
//   * **assignment is a pure function of (members, partitions)** — the
//     range split — so a rebalance is reproducible and reviewable
//     instead of an emergent property of message ordering.

///|
/// A member as the group sees it: identity, where to reach it, and when
/// it last spoke. Liveness is never stored as a flag; it is derived
/// from `last_seen_ms` against a timeout the caller supplies.
pub(all) struct GroupMember {
  id : String
  address : String
  last_seen_ms : Int64
} derive(Debug, Eq, Show)

///|
/// One committed position: the offset the *next* read of this partition
/// should start at (the offset after the last processed record).
pub(all) struct CommitRecord {
  topic : String
  partition : Int
  offset : Int64
} derive(Debug, Eq, Show)

///|
/// A group's whole state. `epoch` is the membership generation and the
/// fence every commit is checked against.
pub(all) struct GroupState {
  group : String
  mut epoch : Int64
  members : Array[GroupMember]
  /// the topics the group consumes; assignment only ever covers these
  topics : Array[String]
  committed : Array[CommitRecord]
} derive(Debug, Eq, Show)

///|
pub(all) suberror GroupError {
  /// The committed epoch is not the current one: this member lost its
  /// partitions when the membership changed.
  StaleEpoch(String)
  /// The member is not in the group (never joined, or swept).
  UnknownMember(String)
  /// The partition is not assigned to this member.
  NotAssigned(String)
  /// A commit may only move forward: going back would re-deliver
  /// records and hide the bug that produced the lower number.
  Regression(String)
}

///|
pub impl Show for GroupError with fn output(self, logger) {
  match self {
    StaleEpoch(msg) => logger.write_string("StaleEpoch(\{msg})")
    UnknownMember(msg) => logger.write_string("UnknownMember(\{msg})")
    NotAssigned(msg) => logger.write_string("NotAssigned(\{msg})")
    Regression(msg) => logger.write_string("Regression(\{msg})")
  }
}

///|
/// One member's share of a topic's partitions.
pub(all) struct MemberAssignment {
  member : String
  partitions : Array[@cluster.PartitionId]
} derive(Debug, Eq, Show)

///|
pub fn new_group(group : String) -> GroupState {
  GroupState::{ group, epoch: 0L, members: [], topics: [], committed: [] }
}

///|
fn find_member(state : GroupState, id : String) -> GroupMember? {
  for member in state.members {
    if member.id == id {
      return Some(member)
    }
  }
  None
}

///|
/// Records that a member spoke. Returns whether the **membership
/// changed** — which is the only event that moves the epoch, because
/// the epoch exists to mark "who holds what" changing.
pub fn observe_member(state : GroupState, member : GroupMember) -> Bool {
  for i = 0; i < state.members.length(); i = i + 1 {
    if state.members[i].id == member.id {
      state.members[i] = member
      return false
    }
  }
  state.members.push(member)
  state.epoch += 1L
  true
}

///|
/// Adds the topics a member declared it consumes. A declaration that
/// changes the set moves the epoch: the assignment the members hold is
/// about to change.
pub fn declare_topics(state : GroupState, topics : Array[String]) -> Bool {
  let mut changed = false
  for topic in topics {
    if !state.topics.contains(topic) {
      state.topics.push(topic)
      changed = true
    }
  }
  if changed {
    state.epoch += 1L
  }
  changed
}

///|
/// Drops members whose last report is older than `timeout_ms`.
/// Returns the ids that left, so the caller reports each departure once
/// rather than every tick (the node table's rule, for the same reason).
pub fn sweep(
  state : GroupState,
  now_ms : Int64,
  timeout_ms : Int64,
) -> Array[String] {
  let gone : Array[String] = []
  let kept : Array[GroupMember] = []
  for member in state.members {
    if now_ms - member.last_seen_ms > timeout_ms {
      gone.push(member.id)
    } else {
      kept.push(member)
    }
  }
  if gone.length() > 0 {
    state.members.clear()
    for member in kept {
      state.members.push(member)
    }
    state.epoch += 1L
  }
  gone
}

///|
/// Range assignment: members sorted by id, partitions sorted by
/// (topic, index) and split into contiguous runs, with the remainder
/// going to the earliest members. Deterministic by construction — the
/// same membership always yields the same assignment, whatever order
/// the reports arrived in.
pub fn assign(
  members : Array[GroupMember],
  partitions : Array[@cluster.PartitionId],
) -> Array[MemberAssignment] {
  let ids : Array[String] = []
  for member in members {
    ids.push(member.id)
  }
  ids.sort_by(fn(a, b) { a.compare(b) })
  let ordered = partitions.copy()
  ordered.sort_by(fn(a, b) {
    let by_topic = a.topic.compare(b.topic)
    if by_topic != 0 {
      by_topic
    } else {
      a.index - b.index
    }
  })
  let out : Array[MemberAssignment] = []
  if ids.length() == 0 {
    return out
  }
  let base = ordered.length() / ids.length()
  let extra = ordered.length() % ids.length()
  let mut cursor = 0
  for i, id in ids {
    let take = base + (if i < extra { 1 } else { 0 })
    let share : Array[@cluster.PartitionId] = []
    for j = 0; j < take; j = j + 1 {
      if cursor + j < ordered.length() {
        share.push(ordered[cursor + j])
      }
    }
    cursor += take
    out.push(MemberAssignment::{ member: id, partitions: share })
  }
  out
}

///|
/// What a member holds right now. A member that is not in the group
/// holds nothing (an empty share), which is also the honest answer for
/// a member that has just been swept.
pub fn assignment_of(
  state : GroupState,
  member : String,
  partitions : Array[@cluster.PartitionId],
) -> Array[@cluster.PartitionId] {
  if find_member(state, member) is None {
    return []
  }
  for share in assign(state.members, partitions) {
    if share.member == member {
      return share.partitions
    }
  }
  []
}

///|
fn committed_offset(
  state : GroupState,
  partition : @cluster.PartitionId,
) -> Int64? {
  for record in state.committed {
    if record.topic == partition.topic && record.partition == partition.index {
      return Some(record.offset)
    }
  }
  None
}

///|
/// Where a read of this partition should resume: the committed offset,
/// or 0 when nothing was ever committed.
pub fn resume_offset(
  state : GroupState,
  partition : @cluster.PartitionId,
) -> Int64 {
  match committed_offset(state, partition) {
    Some(offset) => offset
    None => 0L
  }
}

///|
/// Commits a position. The epoch is the fence: a stale one means this
/// member no longer holds the partition, and its progress must not
/// overwrite whoever does. Offsets only move forward.
pub fn commit(
  state : GroupState,
  member : String,
  epoch : Int64,
  partition : @cluster.PartitionId,
  offset : Int64,
  assigned : Array[@cluster.PartitionId],
) -> Result[Unit, GroupError] {
  if epoch != state.epoch {
    return Err(
      StaleEpoch(
        "commit for \{partition.topic}[\{partition.index}] carries epoch \{epoch}, the group is at \{state.epoch}",
      ),
    )
  }
  if find_member(state, member) is None {
    return Err(UnknownMember("\{member} is not a member of \{state.group}"))
  }
  let mut holds = false
  for p in assigned {
    if p == partition {
      holds = true
    }
  }
  if !holds {
    return Err(
      NotAssigned(
        "\{member} does not hold \{partition.topic}[\{partition.index}]",
      ),
    )
  }
  let previous = match committed_offset(state, partition) {
    Some(previous) => previous
    None => 0L
  }
  if offset < previous {
    return Err(
      Regression(
        "\{partition.topic}[\{partition.index}] is committed at \{previous}; \{offset} would go backwards",
      ),
    )
  }
  if offset == previous {
    return Ok(())
  }
  // upsert: at most one record per partition, so a growing log does not
  // grow this list
  for i = 0; i < state.committed.length(); i = i + 1 {
    let record = state.committed[i]
    if record.topic == partition.topic && record.partition == partition.index {
      state.committed[i] = CommitRecord::{
        topic: partition.topic,
        partition: partition.index,
        offset,
      }
      return Ok(())
    }
  }
  state.committed.push(CommitRecord::{
    topic: partition.topic,
    partition: partition.index,
    offset,
  })
  Ok(())
}

///|
/// The retention floor a group implies for a partition: the caller
/// passes the partition's high watermark, and the answer is the older
/// of "what the replicas have" and "what this group has consumed". A
/// group that has never committed holds nothing back — its next read is
/// offset 0, and 0 means "no floor", which is exactly what a group with
/// no progress should contribute.
///
/// This is where retention and consumer groups meet: without a consumer,
/// the committed prefix is the only thing that bounds deletion; with
/// one, the slowest consumer does.
pub fn retention_floor(
  state : GroupState,
  partition : @cluster.PartitionId,
  high_watermark : Int64,
) -> Int64 {
  match committed_offset(state, partition) {
    Some(offset) =>
      if offset < high_watermark {
        offset
      } else {
        high_watermark
      }
    None => high_watermark
  }
}

///|
/// How far behind a group is on a partition: the records it has not
/// processed yet. Derived, never stored — the same stance the project
/// takes for replica lag.
pub fn lag(
  state : GroupState,
  partition : @cluster.PartitionId,
  log_end : Int64,
) -> Int64 {
  let resume = resume_offset(state, partition)
  if log_end > resume {
    log_end - resume
  } else {
    0L
  }
}
