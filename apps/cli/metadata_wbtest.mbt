// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the metadata store: the rules that must hold no
// matter which backend implements them (the local file today, a CRD
// later).

///|
fn decl(name : String, partitions : Int, rf : Int) -> ClusterMetadataTopic {
  ClusterMetadataTopic::{ name, partitions, replication_factor: rf, }
}

///|
test "creating a topic bumps the version and keeps insertion order" {
  let store = memory_metadata_store()
  let after_first = match create_topic(store, decl("orders", 2, 1)) {
    Ok(metadata) => metadata
    Err(e) => abort("create: \{e}")
  }
  assert_eq(after_first.version, 1L)
  assert_eq(after_first.topics.length(), 1)
  let after_second = match create_topic(store, decl("events", 1, 1)) {
    Ok(metadata) => metadata
    Err(e) => abort("create: \{e}")
  }
  assert_eq(after_second.version, 2L)
  assert_eq(after_second.topics.length(), 2)
  // list is name-sorted so two readers agree regardless of write order
  let listed = match list_topics(store) {
    Ok(topics) => topics
    Err(e) => abort("list: \{e}")
  }
  assert_eq(listed.map(fn(t) { t.name }), ["events", "orders"])
}

///|
test "the store refuses duplicates and invalid declarations" {
  let store = memory_metadata_store()
  let _ = create_topic(store, decl("orders", 1, 1))
  assert_true(create_topic(store, decl("orders", 1, 1)) is Err(Rejected(_)))
  // names go through core/spec's whitelist, so a topic cannot be
  // created that the rest of the system would refuse to open
  assert_true(create_topic(store, decl("Orders", 1, 1)) is Err(Rejected(_)))
  assert_true(create_topic(store, decl("", 1, 1)) is Err(Rejected(_)))
  assert_true(create_topic(store, decl("orders2", 0, 1)) is Err(Rejected(_)))
  assert_true(create_topic(store, decl("orders2", 1, 0)) is Err(Rejected(_)))
  assert_true(create_topic(store, decl("orders2", 1, 99)) is Err(Rejected(_)))
  // and nothing was written by any of those failures
  assert_eq(
    match list_topics(store) {
      Ok(topics) => topics.length()
      Err(_) => -1
    },
    1,
  )
}

///|
test "deleting removes the declaration and reports a miss" {
  let store = memory_metadata_store()
  let _ = create_topic(store, decl("orders", 1, 1))
  let _ = create_topic(store, decl("events", 1, 1))
  let after = match delete_topic(store, "orders") {
    Ok(metadata) => metadata
    Err(e) => abort("delete: \{e}")
  }
  assert_eq(after.topics.length(), 1)
  assert_eq(after.version, 3L)
  // deleting what is not there is an error, not a silent success:
  // "the topic is gone" and "there was never such a topic" differ
  assert_true(delete_topic(store, "orders") is Err(Rejected(_)))
}

///|
test "the local backend round trips through a file" {
  let dir = "/tmp/moonflux_metadata_test"
  let _ = @fs.remove_file(dir)
  let store = file_metadata_store(dir)
  // an unwritten store is empty, not an error
  match (store.load)() {
    Ok(metadata) => {
      assert_eq(metadata.topics.length(), 0)
      assert_eq(metadata.version, 0L)
    }
    Err(e) => abort("empty load: \{e}")
  }
  let _ = create_topic(store, decl("orders", 3, 2))
  // a second store pointing at the same directory sees it: the file is
  // the state, not the process
  let reopened = file_metadata_store(dir)
  let listed = match list_topics(reopened) {
    Ok(topics) => topics
    Err(e) => abort("reopened list: \{e}")
  }
  assert_eq(listed.length(), 1)
  assert_eq(listed[0].partitions, 3)
  assert_eq(listed[0].replication_factor, 2)
  // the rename leaves no temp file behind for a reader to trip over
  match @fs.exists("\{dir}/metadata.json.tmp") {
    Ok(exists) => assert_true(!exists)
    Err(_) => ()
  }
  let _ = @fs.remove_file("\{dir}/metadata.json")
}

// ---------------------------------------------------------------------
// Function sets (P6): rule assets. The rules under test are the asset
// lifecycle (revision monotonic, upsert reporting, delete misses) and
// the validation that decides what may become an asset at all.

///|
fn fn_def(
  name : String,
  params : Array[String],
  body : String,
) -> ClusterMetadataFunction {
  ClusterMetadataFunction::{ name, params, body, description: None, }
}

///|
test "a function set is created at revision 1 and updated in place" {
  let store = memory_metadata_store()
  let first = match
    create_function_set(store, "pricing", [
      fn_def("tax", ["price", "rate"], "price * rate"),
    ]) {
    Ok(set) => set
    Err(e) => abort("create: \{e}")
  }
  assert_eq(first.revision, 1L)
  // an update is a new revision of the same asset, not a second asset
  let second = match
    create_function_set(store, "pricing", [
      fn_def("tax", ["price"], "price * 1.2"),
    ]) {
    Ok(set) => set
    Err(e) => abort("update: \{e}")
  }
  assert_eq(second.revision, 2L)
  let listed = match list_function_sets(store) {
    Ok(sets) => sets
    Err(e) => abort("list: \{e}")
  }
  assert_eq(listed.length(), 1)
  assert_eq(listed[0].revision, 2L)
  assert_eq(listed[0].functions[0].body, "price * 1.2")
}

///|
test "function sets and topics share one document and one version" {
  let store = memory_metadata_store()
  let _ = create_topic(store, decl("orders", 1, 1))
  let _ = create_function_set(store, "pricing", [fn_def("tax", ["p"], "p")])
  // a topic write must not drop the function sets, and vice versa
  let after_delete = match delete_topic(store, "orders") {
    Ok(metadata) => metadata
    Err(e) => abort("delete: \{e}")
  }
  assert_eq(after_delete.function_sets.length(), 1)
  assert_eq(after_delete.version, 3L)
  let _ = delete_function_set(store, "pricing")
  let listed = match list_function_sets(store) {
    Ok(sets) => sets
    Err(e) => abort("list: \{e}")
  }
  assert_eq(listed.length(), 0)
}

///|
test "validation refuses bad assets and writes nothing" {
  let store = memory_metadata_store()
  // names go through the project's one whitelist
  assert_true(
    create_function_set(store, "Pricing V2", [fn_def("tax", ["p"], "p")])
    is Err(Rejected(_)),
  )
  assert_true(
    create_function_set(store, "", [fn_def("tax", ["p"], "p")])
    is Err(Rejected(_)),
  )
  // an empty set is not an asset
  assert_true(create_function_set(store, "empty", []) is Err(Rejected(_)))
  // mbel's name and parameter rules are the authority
  assert_true(
    create_function_set(store, "kws", [fn_def("if", ["p"], "p")])
    is Err(Rejected(_)),
  )
  assert_true(
    create_function_set(store, "dups", [
      fn_def("tax", ["p"], "p"),
      fn_def("tax", ["q"], "q"),
    ])
    is Err(Rejected(_)),
  )
  assert_true(
    create_function_set(store, "badbody", [fn_def("tax", ["p"], "upper(")])
    is Err(Rejected(_)),
  )
  // purity: the clock builtin may appear nowhere in a rule asset
  assert_true(
    create_function_set(store, "impure", [fn_def("tax", ["p"], "now")])
    is Err(Rejected(_)),
  )
  // and none of those attempts left a set behind
  assert_eq(
    match list_function_sets(store) {
      Ok(sets) => sets.length()
      Err(_) => -1
    },
    0,
  )
}

///|
test "the asset document is parsed with unknown fields refused" {
  let good = "{\"name\":\"pricing\",\"version\":1,\"functions\":[{\"name\":\"tax\",\"params\":[\"p\"],\"body\":\"p * 1.2\",\"description\":\"vat\"}]}"
  match parse_function_set_asset(good) {
    Ok((name, functions)) => {
      assert_eq(name, "pricing")
      assert_eq(functions.length(), 1)
      assert_eq(functions[0].params, ["p"])
      assert_eq(functions[0].description, Some("vat"))
    }
    Err(e) => abort("parse: \{e}")
  }
  // a document that says something the platform ignores is refused:
  // an asset must not lie to its reviewer
  let unknown = "{\"name\":\"pricing\",\"env\":{},\"functions\":[]}"
  assert_true(parse_function_set_asset(unknown) is Err(Rejected(_)))
  let bad_field = "{\"name\":\"pricing\",\"functions\":[{\"name\":\"tax\",\"bo dy\":\"p\"}]}"
  assert_true(parse_function_set_asset(bad_field) is Err(Rejected(_)))
  let not_json = "{"
  assert_true(parse_function_set_asset(not_json) is Err(Corrupt(_)))
  // mbel's playground version marker is accepted, and only as 1
  let v2 = "{\"name\":\"pricing\",\"version\":2,\"functions\":[{\"name\":\"tax\",\"params\":[\"p\"],\"body\":\"p\"}]}"
  assert_true(parse_function_set_asset(v2) is Err(Rejected(_)))
}

///|
test "function sets survive a file round trip" {
  let dir = "/tmp/moonflux_metadata_fnset_test"
  let _ = @fs.remove_file(dir)
  let store = file_metadata_store(dir)
  let _ = create_function_set(store, "pricing", [
    fn_def("tax", ["price", "rate"], "price * rate"),
  ])
  let reopened = file_metadata_store(dir)
  let got = match get_function_set(reopened, "pricing") {
    Ok(set) => set
    Err(e) => abort("get: \{e}")
  }
  assert_eq(got.name, "pricing")
  assert_eq(got.revision, 1L)
  assert_eq(got.functions[0].params, ["price", "rate"])
  // a miss is a rejection, not an empty asset
  assert_true(get_function_set(reopened, "nope") is Err(Rejected(_)))
  assert_true(delete_function_set(reopened, "nope") is Err(Rejected(_)))
  let _ = @fs.remove_file("\{dir}/metadata.json")
}

///|
test "the storage policy knobs read the environment" {
  // The app reads its policy from the environment (P8). The gate sets
  // these on a real process; here the process sets them on itself, so
  // the test proves the wiring without depending on the ambient
  // environment it happens to run in.
  @env.set_env_var("MOONFLUX_ROLL_BYTES", "41")
  @env.set_env_var("MOONFLUX_INDEX_EVERY", "7")
  @env.set_env_var("MOONFLUX_RETAIN_BYTES", "4096")
  @env.set_env_var("MOONFLUX_RETAIN_MS", "60000")
  @env.set_env_var("MOONFLUX_ROLL_MS", "30000")
  assert_eq(roll_bytes(), 41)
  assert_eq(index_every_records(), 7)
  let policy = retention_policy()
  assert_eq(policy.max_bytes, 4096)
  assert_eq(policy.max_age_ms, 60000L)
  assert_eq(roll_after_ms(), 30000L)
  // nonsense falls back to the default rather than to something
  // surprising: a typo must not silently turn rolling off or on
  @env.set_env_var("MOONFLUX_ROLL_BYTES", "not a number")
  assert_eq(roll_bytes(), DEFAULT_ROLL_BYTES)
  @env.set_env_var("MOONFLUX_RETAIN_BYTES", "-5")
  assert_eq(retention_policy().max_bytes, 0)
  // and with the knobs removed the policy is simply off
  @env.unset_env_var("MOONFLUX_ROLL_BYTES")
  @env.unset_env_var("MOONFLUX_INDEX_EVERY")
  @env.unset_env_var("MOONFLUX_RETAIN_BYTES")
  @env.unset_env_var("MOONFLUX_RETAIN_MS")
  @env.unset_env_var("MOONFLUX_ROLL_MS")
  assert_eq(roll_bytes(), DEFAULT_ROLL_BYTES)
  assert_eq(index_every_records(), 64)
  assert_eq(retention_policy().max_bytes, 0)
  assert_eq(retention_policy().max_age_ms, 0L)
  assert_eq(roll_after_ms(), 0L)
}

// ---------------------------------------------------------------------
// Consumer groups at the coordinator (P9/T50). The kernel's rules are
// tested in core/group_test; what is tested here is the layer that
// turns requests into them: the fence mapping, what a non-member gets,
// and the floors retention is allowed to see.

///|
fn join_req(
  group : String,
  member : String,
  topics : Array[String],
) -> @client.GroupJoin {
  @client.GroupJoin::{
    group,
    member: @client.WireGroupMember::{ id: member, address: "test:1", },
    topics,
  }
}

///|
/// A registry with one topic declared, so partitions exist to assign.
/// Each test gets its own directory: the registry persists committed
/// offsets, so a shared path would leak one test's commits into the
/// next (which is exactly how the first version of this fixture failed).
fn group_fixture(tag : String, name : String) -> (GroupRegistry, MetadataStore) {
  let store = memory_metadata_store()
  let _ = create_topic(store, decl(name, 2, 1))
  let dir = "/tmp/moonflux_group_fixture_\{tag}"
  let _ = @fs.remove_file("\{dir}/groups.json")
  (GroupRegistry::new(dir, 3000L), store)
}

///|
test "joining assigns the declared partitions and a stale epoch is refused" {
  let (registry, store) = group_fixture("assign", "events")
  let view = match
    registry.join(join_req("g", "m1", ["events"]), store, 1000L) {
    Ok(view) => view
    Err(e) => abort("join: \{e}")
  }
  assert_eq(view.partitions.length(), 2)
  assert_eq(view.members, 1)
  let epoch = view.epoch
  // a commit from the member it holds, at the current generation: fine
  let commit = @client.GroupCommit::{
    group: "g",
    member: "m1",
    epoch,
    topic: "events",
    partition: 0,
    offset: 5L,
  }
  assert_true(registry.commit(commit, store) is Ok(_))
  // the fence: a generation that is not current is refused, whatever
  // member sends it
  let stale = @client.GroupCommit::{
    group: "g",
    member: "m1",
    epoch: epoch - 1L,
    topic: "events",
    partition: 0,
    offset: 9L,
  }
  match registry.commit(stale, store) {
    Err(e) => assert_true("\{e}".contains("epoch"))
    Ok(_) => abort("a stale generation was accepted")
  }
  // a second member moves the generation, so the first member's epoch
  // is stale even though it is still in the group
  let _ = registry.join(join_req("g", "m2", ["events"]), store, 1100L)
  match registry.commit(commit, store) {
    Err(e) => assert_true("\{e}".contains("epoch"))
    Ok(_) =>
      abort("the previous generation was still accepted after a rebalance")
  }
  // and the partition now belongs to someone else: recompute at the
  // current generation and the *other* member's commit is the one that
  // lands — a member only writes what it holds
  let m2_view = match
    registry.join(join_req("g", "m2", ["events"]), store, 1200L) {
    Ok(view) => view
    Err(e) => abort("rejoin: \{e}")
  }
  let mine = m2_view.partitions[0]
  let m1_own = @client.GroupCommit::{
    group: "g",
    member: "m1",
    epoch: m2_view.epoch,
    topic: mine.topic,
    partition: mine.partition,
    offset: 7L,
  }
  match registry.commit(m1_own, store) {
    Err(e) => assert_true("\{e}".contains("does not hold"))
    Ok(_) => abort("a member committed a partition it does not hold")
  }
}

///|
test "a stranger cannot commit, and leaving moves the generation" {
  let (registry, store) = group_fixture("stranger", "events")
  let view = match
    registry.join(join_req("g", "m1", ["events"]), store, 1000L) {
    Ok(view) => view
    Err(e) => abort("join: \{e}")
  }
  let stranger = @client.GroupCommit::{
    group: "g",
    member: "nobody",
    epoch: view.epoch,
    topic: "events",
    partition: 0,
    offset: 1L,
  }
  assert_true(registry.commit(stranger, store) is Err(_))
  // joining an unknown group is an error, not an implicit creation: a
  // member that misspells a group should be told
  let beat = @client.GroupHeartbeat::{
    group: "other",
    member: @client.WireGroupMember::{ id: "m1", address: "test:1", },
  }
  assert_true(registry.heartbeat(beat, store, 1000L) is Err(_))
  // a graceful leave moves the generation immediately
  assert_true(registry.leave("g", "m1") is Ok(_))
  match registry.find("g") {
    Some(state) => {
      assert_true(state.epoch > view.epoch)
      assert_eq(state.members.length(), 0)
    }
    None => abort("the group vanished on leave")
  }
  // leaving a group that does not exist is not an error (idempotent)
  assert_true(registry.leave("g", "m1") is Ok(_))
}

///|
test "floors only reflect groups that actually committed" {
  let (registry, store) = group_fixture("floors", "events")
  let p0 = @cluster.PartitionId::{ topic: "events", index: 0, }
  let p1 = @cluster.PartitionId::{ topic: "events", index: 1, }
  // a group that joined but never committed holds nothing back
  let _ = registry.join(join_req("g", "m1", ["events"]), store, 1000L)
  assert_eq(registry.floors([p0, p1]).length(), 0)
  let view = match
    registry.join(join_req("g", "m1", ["events"]), store, 1100L) {
    Ok(view) => view
    Err(e) => abort("join: \{e}")
  }
  let _ = registry.commit(
    @client.GroupCommit::{
      group: "g",
      member: "m1",
      epoch: view.epoch,
      topic: "events",
      partition: 0,
      offset: 4L,
    },
    store,
  )
  let floors = registry.floors([p0, p1])
  // only the committed partition has a floor: the other one is "no
  // consumer", which is a different fact from "a consumer is at zero"
  assert_eq(floors.length(), 1)
  assert_eq(floors[0].topic, "events")
  assert_eq(floors[0].partition, 0)
  assert_eq(floors[0].floor, 4L)
  // a second group that is further behind lowers the floor: retention
  // must satisfy the slowest reader, not the fastest
  let view2 = match
    registry.join(join_req("g2", "m9", ["events"]), store, 1200L) {
    Ok(view) => view
    Err(e) => abort("join g2: \{e}")
  }
  let _ = registry.commit(
    @client.GroupCommit::{
      group: "g2",
      member: "m9",
      epoch: view2.epoch,
      topic: "events",
      partition: 0,
      offset: 1L,
    },
    store,
  )
  let both = registry.floors([p0])
  assert_eq(both.length(), 1)
  assert_eq(both[0].floor, 1L)
}

///|
test "a group's partitions are the larger of declared and on-disk" {
  let (registry, store) = group_fixture("disk", "events")
  // declared: 2 partitions. disk: partition-0 and partition-2 exist —
  // an index addressed past a hole (`produce --partition 2` on a fresh
  // topic creates partition-2 and nothing else), so the disk truth is
  // "three partitions addressable", and counting entries would have
  // said two
  let base = "/tmp/moonflux_group_fixture_disk"
  let _ = @fs.mkdirs("\{base}/topics/events/partition-0")
  let _ = @fs.mkdirs("\{base}/topics/events/partition-2")
  // the pre-P8 single-file layout also says a partition exists
  let _ = @fs.write_file("\{base}/topics/events/partition-5.log", b"")
  // a file that is not a partition says nothing about partitions
  let _ = @fs.write_file("\{base}/topics/events/topology.json", b"{}")
  let view = match
    registry.join(join_req("g", "m1", ["events"]), store, 1000L) {
    Ok(view) => view
    Err(e) => abort("join: \{e}")
  }
  assert_eq(view.partitions.length(), 6)
  // the share spans the whole disk truth, holes included
  assert_eq(view.partitions[5].partition, 5)
}

///|
test "a coordinator whose data dir hosts no logs enumerates declarations only" {
  // the SC's shape: nothing under <data-dir>/topics, so the disk term
  // of the max is zero and the declaration rules — exactly the pre-P22
  // answer, and the proof that the serve addition did not move the
  // cluster's semantics
  let (registry, store) = group_fixture("nodisk", "events")
  let _ = @fs.mkdirs(
    "/tmp/moonflux_group_fixture_nodisk/topics/other-events/partition-0",
  )
  let view = match
    registry.join(join_req("g", "m1", ["events"]), store, 1000L) {
    Ok(view) => view
    Err(e) => abort("join: \{e}")
  }
  assert_eq(view.partitions.length(), 2)
}
