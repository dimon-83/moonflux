// SPDX-License-Identifier: Apache-2.0
// core/cluster: the control plane's kernel side (P3). Declarative
// specs are the desired state; `reconcile` compares them with the
// observed cluster state and returns the actions that close the gap.
//
// Level-triggered by construction (AGENTS §7, report §1.2.2): the
// function sees only "desired" and "actual", never an event history,
// so a missed or repeated call cannot change the outcome — running it
// twice yields the same actions, and running it on a converged
// cluster yields none. It is pure computation (kernel red lines):
// no IO, no clock, no random; node liveness is an *input* (a node's
// presence in the state), never something this package observes.

///|
/// One data-plane node declaration. `id` is the stable identity a
/// node persists across restarts; `address` is where peers reach it.
pub(all) struct SpuSpec {
  id : String
  address : String
} derive(Debug, Eq, Show)

///|
/// A topic's desired shape: how many partitions, how many replicas
/// each. Placement is derived, never authored (see `place`).
pub(all) struct TopicSpec {
  name : String
  partitions : Int
  replication_factor : Int
} derive(Debug, Eq, Show)

///|
/// The desired state of the cluster.
pub(all) struct ClusterSpec {
  topics : Array[TopicSpec]
  spus : Array[SpuSpec]
} derive(Debug, Eq, Show)

///|
/// A partition's identity: its topic plus its index within the topic.
pub(all) struct PartitionId {
  topic : String
  index : Int
} derive(Debug, Eq, Show)

///|
/// Hashing for placement. FNV-1a over UTF-8 bytes: deterministic
/// across runs and platforms, and independent of any library hash
/// seed — the same spec must always place the same way. The result is
/// masked non-negative so it can index directly (Int wraps on the
/// UInt conversion, and a negative index would abort).
fn fnv1a(s : String) -> Int {
  let mut hash : UInt = 2166136261U
  for i in 0..<s.length() {
    let c = s[i]
    hash = (hash ^ c.to_uint()) * 16777619U
  }
  hash.to_int() & 0x7FFFFFFF
}

///|
/// A partition's observed placement. `leader` is the *assigned*
/// leader (an election outcome persisted by the control plane);
/// replication progress and LRS membership are runtime facts owned
/// by core/replica, not control-plane state.
pub(all) struct ReplicaSet {
  partition : PartitionId
  leader : String
  /// stable placement order; `leader` is always a member
  replicas : Array[String]
} derive(Debug, Eq, Show)

///|
/// The observed state of the cluster: what each partition currently
/// has, as the control plane knows it.
pub(all) struct ClusterState {
  partitions : Array[ReplicaSet]
} derive(Debug, Eq, Show)

///|
/// What the control plane must do to close a gap. Actions are
/// declarative descriptions, not calls: something outside the kernel
/// executes them.
pub(all) enum Action {
  /// Create the partition on this replica set (in this order).
  PlacePartition(PartitionId, Array[String])
  /// Move (or set) the assigned leader of an existing partition.
  AssignLeader(PartitionId, String)
  /// Drop a partition entirely (its topic left the spec).
  RemovePartition(PartitionId)
} derive(Debug, Eq, Show)

///|
/// The spec cannot be reconciled, or the caller asked for something
/// structurally impossible. Reported before any action is computed.
pub(all) suberror ClusterError {
  /// A field is outside its allowed range.
  InvalidSpec(String)
  /// The requested replication cannot be satisfied by these nodes.
  InsufficientNodes(String)
}

///|
pub impl Show for ClusterError with fn output(self, logger) {
  match self {
    InvalidSpec(msg) => logger.write_string("InvalidSpec(\{msg})")
    InsufficientNodes(msg) => logger.write_string("InsufficientNodes(\{msg})")
  }
}

///|
/// Validates node and topic declarations. Sorted-and-unique checks
/// live here so placement can assume a well-formed spec.
pub fn validate_spec(spec : ClusterSpec) -> Result[Unit, ClusterError] {
  if spec.spus.length() == 0 {
    return Err(InvalidSpec("cluster spec needs at least one spu"))
  }
  let seen_ids : Array[String] = []
  for spu in spec.spus {
    if spu.id.length() == 0 || spu.id.length() > 128 {
      return Err(InvalidSpec("spu id must be 1..128 chars"))
    }
    if spu.address.length() == 0 {
      return Err(InvalidSpec("spu \{spu.id} needs an address"))
    }
    if seen_ids.contains(spu.id) {
      return Err(InvalidSpec("duplicate spu id \{spu.id}"))
    }
    seen_ids.push(spu.id)
  }
  let seen_topics : Array[String] = []
  for topic in spec.topics {
    if !@spec.valid_topic_name(topic.name) {
      return Err(InvalidSpec("invalid topic name '\{topic.name}'"))
    }
    if seen_topics.contains(topic.name) {
      return Err(InvalidSpec("duplicate topic \{topic.name}"))
    }
    seen_topics.push(topic.name)
    if topic.partitions <= 0 {
      return Err(
        InvalidSpec("topic \{topic.name} needs at least one partition"),
      )
    }
    if topic.replication_factor <= 0 {
      return Err(
        InvalidSpec("topic \{topic.name} needs a positive replication factor"),
      )
    }
    if topic.replication_factor > spec.spus.length() {
      return Err(
        InsufficientNodes(
          "topic \{topic.name} wants \{topic.replication_factor} replicas but only \{spec.spus.length()} spus are declared",
        ),
      )
    }
  }
  Ok(())
}

///|
/// Node ids in canonical order. Placement must not depend on the
/// order nodes were declared in — otherwise two control planes that
/// see the same cluster would disagree about where a partition lives.
fn sorted_spu_ids(spec : ClusterSpec) -> Array[String] {
  let ids : Array[String] = []
  for spu in spec.spus {
    ids.push(spu.id)
  }
  ids.sort()
  ids
}

///|
/// Deterministic placement: partition `index` of `topic` starts at a
/// name-derived offset in the canonical node order and walks forward,
/// so replicas spread across distinct nodes and repeated calls agree.
/// Rack awareness is a field we have not earned yet (report §1.2.6-A):
/// when it lands, it constrains this walk rather than replacing it.
pub fn place(
  topic : String,
  index : Int,
  replication_factor : Int,
  node_ids : Array[String],
) -> Array[String] {
  let n = node_ids.length()
  let out : Array[String] = []
  if n == 0 {
    return out
  }
  let start = (fnv1a(topic) % n + index % n) % n
  for i in 0..<replication_factor {
    out.push(node_ids[(start + i) % n])
  }
  out
}

///|
/// The partitions a spec implies, in canonical (topic, index) order.
fn desired_partitions(spec : ClusterSpec) -> Array[PartitionId] {
  let topics : Array[TopicSpec] = []
  for topic in spec.topics {
    topics.push(topic)
  }
  topics.sort_by(fn(a, b) { a.name.compare(b.name) })
  let out : Array[PartitionId] = []
  for topic in topics {
    for i in 0..<topic.partitions {
      out.push(PartitionId::{ topic: topic.name, index: i })
    }
  }
  out
}

///|
fn same_replicas(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn find_replica_set(
  state : ClusterState,
  partition : PartitionId,
) -> ReplicaSet? {
  for rs in state.partitions {
    if rs.partition == partition {
      return Some(rs)
    }
  }
  None
}

///|
/// Compares desired and actual state and returns the actions that
/// close the gap, in a stable order (topic, then partition index,
/// then action kind) so two runs are comparable byte for byte.
///
/// Level-triggered contract: the result depends only on
/// `(state, spec)`. On a converged cluster it is empty.
pub fn reconcile(
  state : ClusterState,
  spec : ClusterSpec,
) -> Result[Array[Action], ClusterError] {
  match validate_spec(spec) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let node_ids = sorted_spu_ids(spec)
  let wanted = desired_partitions(spec)
  let actions : Array[Action] = []
  for partition in wanted {
    let desired = place(
      partition.topic,
      partition.index,
      replication_factor_of(spec, partition.topic),
      node_ids,
    )
    match find_replica_set(state, partition) {
      None => {
        // new partition: placement first, then its initial leader
        actions.push(PlacePartition(partition, desired))
        actions.push(AssignLeader(partition, desired[0]))
      }
      Some(current) =>
        if same_replicas(current.replicas, desired) {
          // converged — but a leader that is no longer a member (its
          // node left the cluster) must be reassigned
          if !desired.contains(current.leader) {
            actions.push(AssignLeader(partition, desired[0]))
          }
        } else {
          // the node set changed under this partition
          actions.push(PlacePartition(partition, desired))
          if !desired.contains(current.leader) {
            actions.push(AssignLeader(partition, desired[0]))
          }
        }
    }
  }
  // partitions whose topic left the spec are removed; they are walked
  // in state order, which `canonical_state` keeps sorted
  for rs in state.partitions {
    let mut still_wanted = false
    for partition in wanted {
      if partition == rs.partition {
        still_wanted = true
        break
      }
    }
    if !still_wanted {
      actions.push(RemovePartition(rs.partition))
    }
  }
  Ok(actions)
}

///|
/// The replication factor a topic asks for (validated already).
fn replication_factor_of(spec : ClusterSpec, topic : String) -> Int {
  for t in spec.topics {
    if t.name == topic {
      return t.replication_factor
    }
  }
  1
}

///|
/// Canonical ordering for state: by topic, then partition index. The
/// control plane stores state this way so diffs and tests are stable
/// regardless of the order partitions were created in.
pub fn canonical_state(state : ClusterState) -> ClusterState {
  let sorted : Array[ReplicaSet] = []
  for rs in state.partitions {
    sorted.push(rs)
  }
  sorted.sort_by(fn(a, b) {
    let by_topic = a.partition.topic.compare(b.partition.topic)
    if by_topic != 0 {
      by_topic
    } else {
      a.partition.index.compare(b.partition.index)
    }
  })
  ClusterState::{ partitions: sorted }
}

///|
/// Applies actions to a state — the inverse of `reconcile`, and the
/// piece the control plane's executor is built on. Kept in the kernel
/// so that "reconcile then apply" is testable without any node.
pub fn apply_actions(
  state : ClusterState,
  actions : Array[Action],
) -> ClusterState {
  let partitions : Array[ReplicaSet] = []
  for rs in state.partitions {
    partitions.push(rs)
  }
  for action in actions {
    match action {
      PlacePartition(partition, replicas) => {
        let mut found = false
        for i in 0..<partitions.length() {
          if partitions[i].partition == partition {
            // placement preserves the existing leader if it survives
            let leader = partitions[i].leader
            let leader = if replicas.contains(leader) {
              leader
            } else {
              replicas[0]
            }
            partitions[i] = ReplicaSet::{ partition, leader, replicas }
            found = true
            break
          }
        }
        if !found {
          partitions.push(ReplicaSet::{
            partition,
            leader: replicas[0],
            replicas,
          })
        }
      }
      AssignLeader(partition, leader) =>
        for i in 0..<partitions.length() {
          if partitions[i].partition == partition {
            let rs = partitions[i]
            partitions[i] = ReplicaSet::{
              partition: rs.partition,
              leader,
              replicas: rs.replicas,
            }
            break
          }
        }
      RemovePartition(partition) => {
        let kept : Array[ReplicaSet] = []
        for rs in partitions {
          if rs.partition != partition {
            kept.push(rs)
          }
        }
        partitions.clear()
        for rs in kept {
          partitions.push(rs)
        }
      }
    }
  }
  canonical_state(ClusterState::{ partitions, })
}
