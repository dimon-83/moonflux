// SPDX-License-Identifier: Apache-2.0
// The rules under test are the ones that decide who may move a high
// watermark and who may only read. A wrong answer here is not a bug in
// a feature; it is the absence of one.

///|
fn cred(name : String, token : String, role : @auth.Role) -> @auth.Credential {
  @auth.Credential::{ name, token, role, grants: [] }
}

///|
test "roles resolve from tokens, and nothing else does" {
  let table = [
    cred("operator", "s3cret-root", @auth.Root),
    cred("app", "s3cret-app", @auth.ReadWrite),
    cred("dash", "s3cret-dash", @auth.ReadOnly),
    cred("spu-b", "s3cret-node", @auth.Node),
  ]
  assert_eq(
    @auth.authenticate(table, "s3cret-app"),
    Some(@auth.Identity::{ name: "app", role: ReadWrite, grants: [] }),
  )
  assert_eq(@auth.authenticate(table, "wrong"), None)
  assert_eq(@auth.authenticate(table, ""), None)
  // a table with no entries authenticates nobody — "no credentials
  // configured" must never mean "everyone is welcome"
  assert_eq(@auth.authenticate([], "s3cret-root"), None)
}

///|
test "the permission table is closed: unlisted commands fail closed" {
  // reads: every role that can read, can read the same things —
  // including the "where does this partition live" question (P22): a
  // consumer that may read the data must be able to find it, and a
  // node's placement fallback keeps working (it stays in
  // is_node_command too)
  let reads = [
    @client.CMD_FETCH,
    @client.CMD_FETCH_COMMITTED,
    @client.CMD_FETCH_PARTITION,
    @client.CMD_OFFSET_INFO,
    @client.CMD_SEGMENTS,
    @client.CMD_LEADER,
  ]
  for cmd in reads {
    // 9001 stands in for "a command someone adds next year"
    assert_true(@auth.permit(Root, cmd))
    assert_true(@auth.permit(ReadWrite, cmd))
    assert_true(@auth.permit(ReadOnly, cmd))
  }
  assert_true(@auth.permit(Node, @client.CMD_LEADER))
  // writes: root and read-write, never read-only
  let writes = [
    @client.CMD_PRODUCE,
    @client.CMD_PRODUCE_PARTITION,
    // compaction deletes records: it is a write, not a read, and a
    // read-only identity must not be able to shrink a log
    @client.CMD_COMPACT,
  ]
  for cmd in writes {
    assert_true(@auth.permit(Root, cmd))
    assert_true(@auth.permit(ReadWrite, cmd))
    assert_true(!@auth.permit(ReadOnly, cmd))
    assert_true(!@auth.permit(Node, cmd))
  }
  // the control-plane's assets: root only
  let admin = [
    @client.CMD_TOPIC_CREATE,
    @client.CMD_TOPIC_DELETE,
    @client.CMD_FUNCTION_SET_CREATE,
    @client.CMD_FUNCTION_SET_DELETE,
    @client.CMD_CLUSTER_PIPELINE_APPLY,
  ]
  for cmd in admin {
    assert_true(@auth.permit(Root, cmd))
    assert_true(!@auth.permit(ReadWrite, cmd))
    assert_true(!@auth.permit(ReadOnly, cmd))
    assert_true(!@auth.permit(Node, cmd))
  }
  // and the closed direction: an unknown command is denied for every
  // non-root role, so forgetting to classify a new one is a denial that
  // a test notices, not an open door nobody notices
  let non_root : Array[@auth.Role] = [ReadWrite, ReadOnly, Node]
  for role in non_root {
    assert_true(!@auth.permit(role, 9001))
  }
  assert_true(@auth.permit(Root, 9001))
}

///|
test "node commands are node-only: forging a watermark is not a privilege" {
  // these are the ones whose forgery is an integrity problem, not a
  // privacy one: SYNC_ACK moves the high watermark, REGISTER puts a
  // phantom replica into the set whose minimum defines it
  let node_only = [
    @client.CMD_REGISTER,
    @client.CMD_HEARTBEAT,
    @client.CMD_SYNC_FETCH,
    @client.CMD_SYNC_ACK,
    @client.CMD_CONFIRM,
  ]
  for cmd in node_only {
    assert_true(@auth.permit(Node, cmd))
    assert_true(!@auth.permit(ReadWrite, cmd))
    assert_true(!@auth.permit(ReadOnly, cmd))
    // even read-write must not be able to ack a position it does not hold
  }
  // a consumer's own group is not an admin privilege either
  assert_true(@auth.permit(ReadWrite, @client.CMD_GROUP_COMMIT))
  assert_true(!@auth.permit(ReadOnly, @client.CMD_GROUP_COMMIT))
  assert_true(!@auth.permit(Node, @client.CMD_GROUP_COMMIT))
}

///|
test "token comparison does not leak where a difference is" {
  assert_true(@auth.constant_time_eq("s3cret", "s3cret"))
  assert_true(!@auth.constant_time_eq("s3cret", "s3creu"))
  // a shared prefix is not "closer" than a different first byte: both
  // are simply unequal
  assert_true(!@auth.constant_time_eq("s3cret", "s3cre"))
  assert_true(!@auth.constant_time_eq("s3cre", "s3cret"))
  assert_true(!@auth.constant_time_eq("", "s3cret"))
  assert_true(@auth.constant_time_eq("", ""))
  // roles parse from their wire names and nothing else
  assert_eq(@auth.parse_role("read-write"), Ok(ReadWrite))
  assert_true(@auth.parse_role("admin") is Err(_))
  assert_eq(@auth.role_name(Node), "node")
}

///|
test "authorize_topic: no grants means the role alone governs" {
  let identity = @auth.Identity::{ name: "app", role: ReadWrite, grants: [] }
  assert_true(@auth.authorize_topic(identity, "events", write=true) is Ok(_))
  assert_true(@auth.authorize_topic(identity, "events", write=false) is Ok(_))
  let reader = @auth.Identity::{ name: "ro", role: ReadOnly, grants: [] }
  // the ROLE table still governs kind: this second gate narrows, it
  // does not widen (the runner checks permit first)
  assert_true(@auth.authorize_topic(reader, "events", write=true) is Ok(_))
}

///|
test "authorize_topic: grants narrow to their topics" {
  let granted = [
    @auth.TopicGrant::{ topic: "orders", read: true, write: true },
    @auth.TopicGrant::{ topic: "audit", read: true, write: false },
  ]
  let identity = @auth.Identity::{
    name: "svc",
    role: ReadWrite,
    grants: granted,
  }
  // granted topics: read and write as granted
  assert_true(@auth.authorize_topic(identity, "orders", write=true) is Ok(_))
  assert_true(@auth.authorize_topic(identity, "orders", write=false) is Ok(_))
  assert_true(@auth.authorize_topic(identity, "audit", write=false) is Ok(_))
  // audit is read-granted only: the write refusal names user, verb, topic
  match @auth.authorize_topic(identity, "audit", write=true) {
    Err(message) => {
      assert_true(message.contains("svc"))
      assert_true(message.contains("may not write"))
      assert_true(message.contains("audit"))
    }
    Ok(_) => abort("a read-only grant permitted a write")
  }
  // a topic the grants do not cover: the refusal says so
  match @auth.authorize_topic(identity, "other", write=true) {
    Err(message) => assert_true(message.contains("cover other topics"))
    Ok(_) => abort("an ungranted topic was allowed")
  }
}

///|
test "authorize_topic: nodes and root are infrastructure, not tenants" {
  let node = @auth.Identity::{ name: "spu-a", role: Node, grants: [] }
  assert_true(@auth.authorize_topic(node, "anything", write=true) is Ok(_))
  let root = @auth.Identity::{
    name: "root",
    role: Root,
    grants: [@auth.TopicGrant::{ topic: "narrow", read: true, write: false }],
  }
  // even a Root whose grants would narrow it stays Root: grants narrow
  // tenants, and the operator is not one
  assert_true(@auth.authorize_topic(root, "anything", write=true) is Ok(_))
}
