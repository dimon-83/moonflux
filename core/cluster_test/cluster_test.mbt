// Blackbox tests for moonflux/core/cluster: the control plane's
// level-triggered contract — convergence, idempotence, determinism,
// and the placement rules that must not depend on declaration order.

///|
fn spu(id : String) -> @cluster.SpuSpec {
  @cluster.SpuSpec::{ id, address: "127.0.0.1:0" }
}

///|
fn topic(name : String, partitions : Int, rf : Int) -> @cluster.TopicSpec {
  @cluster.TopicSpec::{ name, partitions, replication_factor: rf }
}

///|
fn spec(
  spus : Array[@cluster.SpuSpec],
  topics : Array[@cluster.TopicSpec],
) -> @cluster.ClusterSpec {
  @cluster.ClusterSpec::{ topics, spus }
}

///|
fn empty_state() -> @cluster.ClusterState {
  @cluster.ClusterState::{ partitions: [] }
}

///|
/// Runs reconcile and aborts with the error, so tests read as
/// assertions on the happy path.
fn reconcile_ok(
  state : @cluster.ClusterState,
  spec : @cluster.ClusterSpec,
) -> Array[@cluster.Action] {
  match @cluster.reconcile(state, spec) {
    Ok(actions) => actions
    Err(e) => abort("reconcile failed: \{e}")
  }
}

///|
/// Applies the reconciled actions, i.e. one full control-plane pass.
fn converge(
  state : @cluster.ClusterState,
  spec : @cluster.ClusterSpec,
) -> @cluster.ClusterState {
  @cluster.apply_actions(state, reconcile_ok(state, spec))
}

///|
test "a fresh cluster places every partition and picks a leader" {
  let s = spec([spu("spu-a"), spu("spu-b"), spu("spu-c")], [
    topic("events", 3, 2),
  ])
  let actions = reconcile_ok(empty_state(), s)
  // 3 partitions x (place + leader)
  assert_eq(actions.length(), 6)
  assert_true(actions[0] is PlacePartition(_))
  assert_true(actions[1] is AssignLeader(_))
  match actions[0] {
    PlacePartition(pid, replicas) => {
      assert_eq(pid.topic, "events")
      assert_eq(pid.index, 0)
      assert_eq(replicas.length(), 2)
      // replicas are distinct nodes
      assert_true(replicas[0] != replicas[1])
    }
    _ => abort("expected PlacePartition")
  }
  match actions[1] {
    AssignLeader(_, leader) => assert_true(leader.length() > 0)
    _ => abort("expected AssignLeader")
  }
}

///|
test "reconcile is idempotent: a converged cluster needs no action" {
  let s = spec([spu("spu-a"), spu("spu-b")], [topic("events", 2, 2)])
  let state = converge(empty_state(), s)
  let again = reconcile_ok(state, s)
  assert_eq(again.length(), 0)
  // and applying nothing changes nothing
  assert_eq(@cluster.apply_actions(state, again), state)
}

///|
test "placement does not depend on declaration order" {
  let forward = spec([spu("spu-a"), spu("spu-b"), spu("spu-c")], [
    topic("events", 3, 2),
    topic("logs", 2, 1),
  ])
  let backward = spec([spu("spu-c"), spu("spu-b"), spu("spu-a")], [
    topic("logs", 2, 1),
    topic("events", 3, 2),
  ])
  let a = converge(empty_state(), forward)
  let b = converge(empty_state(), backward)
  assert_eq(a, b)
}

///|
test "placement spreads replicas and rotates across partitions" {
  let s = spec([spu("spu-a"), spu("spu-b"), spu("spu-c")], [
    topic("events", 3, 1),
  ])
  let state = converge(empty_state(), s)
  let firsts : Array[String] = []
  for rs in state.partitions {
    firsts.push(rs.replicas[0])
  }
  // a single-replica topic walks the node list: all three are used
  assert_eq(firsts.length(), 3)
  assert_true(firsts[0] != firsts[1])
  assert_true(firsts[1] != firsts[2])
  assert_true(firsts[0] != firsts[2])
}

///|
test "adding a node reshapes placement and keeps a surviving leader" {
  let before = spec([spu("spu-a"), spu("spu-b")], [topic("events", 2, 2)])
  let state = converge(empty_state(), before)
  let after = spec([spu("spu-a"), spu("spu-b"), spu("spu-c")], [
    topic("events", 2, 2),
  ])
  let actions = reconcile_ok(state, after)
  assert_true(actions.length() > 0)
  let reshaped = converge(state, after)
  // invariants hold after the reshape: rf members, leader is a member
  for rs in reshaped.partitions {
    assert_eq(rs.replicas.length(), 2)
    assert_true(rs.replicas.contains(rs.leader))
  }
  // the new node earns work: a two-slot walk over three nodes must
  // reach it on at least one partition
  let mut uses_new = false
  for rs in reshaped.partitions {
    if rs.replicas.contains("spu-c") {
      uses_new = true
    }
  }
  assert_true(uses_new)
  // converged again
  assert_eq(reconcile_ok(reshaped, after).length(), 0)
}

///|
test "removing the leader's node reassigns the leader" {
  let before = spec([spu("spu-a"), spu("spu-b"), spu("spu-c")], [
    topic("events", 1, 2),
  ])
  let state = converge(empty_state(), before)
  let leader = state.partitions[0].leader
  // drop the node that happens to hold the leadership
  let survivors : Array[@cluster.SpuSpec] = []
  for s in before.spus {
    if s.id != leader {
      survivors.push(s)
    }
  }
  let after = spec(survivors, [topic("events", 1, 2)])
  let actions = reconcile_ok(state, after)
  let mut reassigned : String? = None
  for action in actions {
    match action {
      AssignLeader(_, new_leader) => reassigned = Some(new_leader)
      _ => ()
    }
  }
  match reassigned {
    Some(new_leader) => assert_true(new_leader != leader)
    None => abort("expected the leader to be reassigned")
  }
  // and the leader is a member of the new replica set
  let reshaped = converge(state, after)
  assert_true(
    reshaped.partitions[0].replicas.contains(reshaped.partitions[0].leader),
  )
  assert_true(!reshaped.partitions[0].replicas.contains(leader))
}

///|
test "a topic leaving the spec removes its partitions" {
  let before = spec([spu("spu-a"), spu("spu-b")], [
    topic("events", 2, 1),
    topic("logs", 1, 1),
  ])
  let state = converge(empty_state(), before)
  assert_eq(state.partitions.length(), 3)
  let after = spec([spu("spu-a"), spu("spu-b")], [topic("events", 2, 1)])
  let actions = reconcile_ok(state, after)
  assert_eq(actions.length(), 1)
  assert_true(actions[0] is RemovePartition(_))
  let shrunk = converge(state, after)
  assert_eq(shrunk.partitions.length(), 2)
  assert_eq(reconcile_ok(shrunk, after).length(), 0)
}

///|
test "spec validation reports what cannot be reconciled" {
  let no_spus = spec([], [topic("events", 1, 1)])
  assert_true(@cluster.validate_spec(no_spus) is Err(InvalidSpec(_)))

  let dup_spu = spec([spu("spu-a"), spu("spu-a")], [topic("events", 1, 1)])
  assert_true(@cluster.validate_spec(dup_spu) is Err(InvalidSpec(_)))

  let dup_topic = spec([spu("spu-a")], [
    topic("events", 1, 1),
    topic("events", 1, 1),
  ])
  assert_true(@cluster.validate_spec(dup_topic) is Err(InvalidSpec(_)))

  let bad_name = spec([spu("spu-a")], [topic("Events", 1, 1)])
  assert_true(@cluster.validate_spec(bad_name) is Err(InvalidSpec(_)))

  let zero_parts = spec([spu("spu-a")], [topic("events", 0, 1)])
  assert_true(@cluster.validate_spec(zero_parts) is Err(InvalidSpec(_)))

  // asking for more replicas than nodes is a capacity problem, not a
  // typo — a distinct error variant so operators can tell them apart
  let too_many = spec([spu("spu-a")], [topic("events", 1, 2)])
  assert_true(@cluster.validate_spec(too_many) is Err(InsufficientNodes(_)))

  // and reconcile refuses before producing any action
  match @cluster.reconcile(empty_state(), too_many) {
    Err(InsufficientNodes(_)) => ()
    Ok(actions) => abort("expected refusal, got \{actions.length()} actions")
    Err(e) => abort("expected InsufficientNodes, got \{e}")
  }
}

///|
test "placement walks distinct nodes for a full replica set" {
  let nodes = ["a", "b", "c", "d"]
  for index in 0..<8 {
    let replicas = @cluster.place("events", index, 3, nodes)
    assert_eq(replicas.length(), 3)
    assert_true(replicas[0] != replicas[1])
    assert_true(replicas[1] != replicas[2])
    assert_true(replicas[0] != replicas[2])
  }
  // deterministic: same inputs, same placement
  assert_eq(
    @cluster.place("events", 2, 2, nodes),
    @cluster.place("events", 2, 2, nodes),
  )
}
