// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the metadata store: the rules that must hold no
// matter which backend implements them (the local file today, a CRD
// later).

///|
fn decl(name : String, partitions : Int, rf : Int) -> ClusterMetadataTopic {
  ClusterMetadataTopic::{ name, partitions, replication_factor: rf }
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
