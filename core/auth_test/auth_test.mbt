// SPDX-License-Identifier: Apache-2.0
// The rules under test are the ones that decide who may move a high
// watermark and who may only read. A wrong answer here is not a bug in
// a feature; it is the absence of one.

///|
fn cred(name : String, token : String, role : @auth.Role) -> @auth.Credential {
  @auth.Credential::{ name, token, role }
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
    Some(@auth.Identity::{ name: "app", role: ReadWrite }),
  )
  assert_eq(@auth.authenticate(table, "wrong"), None)
  assert_eq(@auth.authenticate(table, ""), None)
  // a table with no entries authenticates nobody — "no credentials
  // configured" must never mean "everyone is welcome"
  assert_eq(@auth.authenticate([], "s3cret-root"), None)
}

///|
test "the permission table is closed: unlisted commands fail closed" {
  // reads: every role that can read, can read the same things
  let reads = [
    @client.CMD_FETCH,
    @client.CMD_FETCH_COMMITTED,
    @client.CMD_FETCH_PARTITION,
    @client.CMD_OFFSET_INFO,
    @client.CMD_SEGMENTS,
  ]
  for cmd in reads {
    // 9001 stands in for "a command someone adds next year"
    assert_true(@auth.permit(Root, cmd))
    assert_true(@auth.permit(ReadWrite, cmd))
    assert_true(@auth.permit(ReadOnly, cmd))
  }
  // writes: root and read-write, never read-only
  let writes = [@client.CMD_PRODUCE, @client.CMD_PRODUCE_PARTITION]
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
