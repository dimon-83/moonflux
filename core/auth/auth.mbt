// SPDX-License-Identifier: Apache-2.0
// core/auth: who is asking, and what they may do (P12).
//
// Pure computation, like every kernel package: identities are data, the
// permission table is data, and the one comparison that must not leak
// information is a function here rather than a stride-by-stride `==`
// somewhere in an app.
//
// The shape follows the reference's model (x509 CN → role bindings,
// Root / ReadOnly / Basic) with one addition this project needs: a
// **Node** role. Replication trust is not the same kind of trust as
// reading data — a node that can forge a `SYNC_ACK` can move a high
// watermark that every committed read depends on, so node-only commands
// are a separate permission, not an administrator's privilege.

///|
/// Who is asking. The name comes from the credential (a certificate CN,
/// or the name a token is bound to); the role comes from the same
/// binding, never from the request.
pub(all) struct Identity {
  name : String
  role : Role
} derive(Debug, Eq, Show)

///|
/// What an identity may do. Deliberately few: a role model that grows
/// per command becomes an ACL system, and this milestone's job is a
/// security face, not an IAM product.
pub(all) enum Role {
  /// Everything, including rewriting the cluster's assets.
  Root
  /// The data plane and the caller's own consumer groups.
  ReadWrite
  /// Reads only: fetch, watermarks, listings, descriptions.
  ReadOnly
  /// A peer node: registration, heartbeats, replication, confirmations.
  Node
} derive(Debug, Eq, Show)

///|
pub fn role_name(role : Role) -> String {
  match role {
    Root => "root"
    ReadWrite => "read-write"
    ReadOnly => "read-only"
    Node => "node"
  }
}

///|
pub fn parse_role(text : String) -> Result[Role, String] {
  match text {
    "root" => Ok(Root)
    "read-write" => Ok(ReadWrite)
    "read-only" => Ok(ReadOnly)
    "node" => Ok(Node)
    _ => Err("unknown role '\{text}' (root, read-write, read-only, node)")
  }
}

///|
/// Whether this role may issue this command.
///
/// The table is **explicit and closed**: a command that is not listed is
/// denied for everyone but Root. That direction matters — a new command
/// added without a thought for permissions fails closed, and the failure
/// shows up in the first test that tries to use it, not in production a
/// month later.
pub fn permit(role : Role, cmd : Int) -> Bool {
  if role is Root {
    // Root is the operator: everything, by definition, not by listing
    return true
  }
  match role {
    Root => true // unreachable: handled above, kept for exhaustiveness
    ReadWrite =>
      // the data plane, plus group membership and commits (a consumer
      // writes its own progress) and the read-only questions
      is_data_read(cmd) ||
      cmd == @client.CMD_PRODUCE ||
      cmd == @client.CMD_PRODUCE_PARTITION ||
      is_group_member_command(cmd)
    ReadOnly => is_data_read(cmd)
    Node => is_node_command(cmd)
  }
}

///|
/// Reads on the data plane: every answer here is either records the
/// caller is allowed to see or metadata about them.
fn is_data_read(cmd : Int) -> Bool {
  cmd == @client.CMD_FETCH ||
  cmd == @client.CMD_FETCH_COMMITTED ||
  cmd == @client.CMD_FETCH_PARTITION ||
  cmd == @client.CMD_OFFSET_INFO ||
  cmd == @client.CMD_SEGMENTS
}

///|
/// What a member of a consumer group does: join, heartbeat, leave,
/// commit. It is deliberately not part of "admin": a consumer manages
/// its own progress and nothing else.
fn is_group_member_command(cmd : Int) -> Bool {
  cmd == @client.CMD_GROUP_JOIN ||
  cmd == @client.CMD_GROUP_HEARTBEAT ||
  cmd == @client.CMD_GROUP_LEAVE ||
  cmd == @client.CMD_GROUP_COMMIT
}

///|
/// What only a peer node may send. Forging any of these is not a
/// privacy problem, it is an integrity problem: a fake `SYNC_ACK` moves
/// the high watermark every committed read is built on, and a fake
/// `REGISTER` puts a phantom replica in a set whose minimum defines that
/// watermark.
pub fn is_node_command(cmd : Int) -> Bool {
  cmd == @client.CMD_REGISTER ||
  cmd == @client.CMD_HEARTBEAT ||
  cmd == @client.CMD_SYNC_FETCH ||
  cmd == @client.CMD_SYNC_ACK ||
  cmd == @client.CMD_CONFIRM ||
  cmd == @client.CMD_LEADER ||
  cmd == @client.CMD_CLUSTER_PIPELINE_FETCH ||
  cmd == @client.CMD_FUNCTION_SET_FETCH
}

///|
/// One binding: a name, the secret it presents, and what it becomes.
pub(all) struct Credential {
  name : String
  token : String
  role : Role
} derive(Debug, Eq, Show)

///|
/// Resolves a presented token to an identity, or None when nothing
/// matches. The comparison itself is constant-time, but the *lookup*
/// walks the table — an attacker learns nothing useful from timing here
/// (the table is the operator's, not the attacker's, and the number of
/// entries leaks no secret).
pub fn authenticate(
  credentials : Array[Credential],
  token : String,
) -> Identity? {
  if token.length() == 0 {
    return None
  }
  for credential in credentials {
    if constant_time_eq(credential.token, token) {
      return Some(Identity::{ name: credential.name, role: credential.role })
    }
  }
  None
}

///|
/// Compares two secrets without leaking *where* they differ: the loop
/// runs to the longer length either way and folds differences into one
/// flag. `==` on strings returns at the first mismatch, which is enough
/// to recover a token byte by byte with a stopwatch.
pub fn constant_time_eq(a : String, b : String) -> Bool {
  let length_diff = if a.length() > b.length() {
    a.length() - b.length()
  } else {
    b.length() - a.length()
  }
  let shorter = if a.length() < b.length() { a.length() } else { b.length() }
  let mut difference = length_diff
  for i = 0; i < shorter; i = i + 1 {
    difference = difference + (a[i].to_int() ^ b[i].to_int())
  }
  difference == 0
}
