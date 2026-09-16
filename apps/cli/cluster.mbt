// SPDX-License-Identifier: Apache-2.0
// cluster: the control-plane view from the command line (P3).
// Read-only for now: `nodes` asks a control plane what it can see.
// Mutating verbs (topic create, then placement per docs/cli-roadmap.md
// §3.3) arrive with the metadata store in T24 — a command that
// changes cluster state must land together with the state it changes.

///|
/// `moonflux cluster <verb> [flags]`
fn cmd_cluster(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("cluster: missing verb (nodes)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "nodes" => cluster_nodes(rest)
    _ => fail("cluster: unknown verb '\{verb}' (known: nodes)")
  }
}

///|
/// `moonflux cluster nodes --remote host:port` — prints the online
/// nodes the control plane knows, one per line:
///   <id>:<role>\t<address>\tleo=<n>
/// Sorted by the control plane, so repeated reads are comparable.
fn cluster_nodes(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = match flags.get("remote") {
    Some(remote) => remote
    None =>
      fail(
        "cluster nodes: --remote host:port is required (a control plane must be asked, not guessed)",
      )
  }
  let payload = match control_call(remote, @client.CMD_NODES, b"") {
    Ok(payload) => payload
    Err(e) => fail("cluster nodes: \{e}")
  }
  let nodes = match @client.decode_nodes(payload) {
    Ok(nodes) => nodes
    Err(e) => fail("cluster nodes: \{e}")
  }
  for node in nodes {
    println(
      "\{node.id}:\{@client.role_name(node.role)}\t\{node.address}\tleo=\{node.leo}",
    )
  }
  cli_exit(0)
}
