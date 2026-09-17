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
  ClusterMetadataFunction::{ name, params, body, description: None }
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
