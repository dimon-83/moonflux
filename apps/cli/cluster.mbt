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
    "status" => cluster_status(rest)
    "leader" => cluster_leader(rest)
    "offsets" => cluster_offsets(rest)
    "segments" => cluster_segments(rest)
    _ =>
      fail(
        "cluster: unknown verb '\{verb}' (known: nodes, status, leader, offsets, segments)",
      )
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
  let payload = match
    control_call_with_token(remote, @client.CMD_NODES, b"", client_token(flags)) {
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

///|
/// `moonflux cluster leader --topic T [--partition N] --remote <control
/// plane>` — prints the address that leads that partition (partition 0
/// when the flag is absent), or nothing when the control plane has no
/// assignment (a legitimate state: the exit code distinguishes it from
/// a failed query).
fn cluster_leader(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  let ref = @client.PartitionRef::{ topic, partition }
  let payload = match
    control_call_with_token(
      remote,
      @client.CMD_LEADER,
      @client.encode_partition_ref(ref),
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("cluster leader: \{e}")
  }
  let view = match @client.decode_partition_view(payload) {
    Ok(view) => view
    Err(e) => fail("cluster leader: \{e}")
  }
  if view.leader.length() == 0 {
    cli_exit(3) // no assignment yet — not an error
  }
  println(view.leader)
  cli_exit(0)
}

///|
/// `moonflux cluster offsets --topic T [--partition N] --remote <node>`
/// — prints `<hw> <leo>` for the partition, asked of the node that
/// holds it (the leader owns the progress ledger; asking a follower
/// would answer a different question).
fn cluster_offsets(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  // the request always names its partition (P7): watermarks are per
  // partition, so there is no "the" watermark to ask for implicitly
  let ask = @client.encode_partition_ref(@client.PartitionRef::{
    topic,
    partition,
  })
  let payload = match
    control_call_with_token(
      remote,
      @client.CMD_OFFSET_INFO,
      ask,
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("cluster offsets: \{e}")
  }
  let (hw, leo) = match @client.decode_offset_info(payload) {
    Ok(pair) => pair
    Err(e) => fail("cluster offsets: \{e}")
  }
  println("\{hw} \{leo}")
  cli_exit(0)
}

///|
/// `--partition N`: one rule for the flag, wherever it appears.
fn parse_partition_flag(text : String) -> Int {
  match (try? @string.parse_int(text[0:text.length()])) {
    Ok(n) if n >= 0 => n
    _ => fail("--partition expects a non-negative integer, got \{text}")
  }
}

///|
/// `moonflux cluster segments --topic T [--partition N] --remote <node>`
/// — the partition's segments, oldest first: which offsets each covers
/// and how many bytes it costs. Asked of the node that holds the
/// partition, because the disk is that node's fact (P8).
fn cluster_segments(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  let ref = @client.PartitionRef::{ topic, partition }
  let payload = match
    control_call_with_token(
      remote,
      @client.CMD_SEGMENTS,
      @client.encode_partition_ref(ref),
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("cluster segments: \{e}")
  }
  let segments = match @client.decode_wire_segments(payload) {
    Ok(segments) => segments
    Err(e) => fail("cluster segments: \{e}")
  }
  for seg in segments {
    println("\{seg.base}\t\{seg.records}\t\{seg.bytes}")
  }
  cli_exit(0)
}

///|
/// `moonflux cluster status --remote <control plane>` — the operator's
/// one-screen view: the nodes it can see, the topics declared, and who
/// leads each partition. It asks the control plane for the placement
/// and each leader for its watermarks, so the numbers are the leaders'
/// own rather than the control plane's memory of them.
fn cluster_status(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let nodes_payload = match
    control_call_with_token(remote, @client.CMD_NODES, b"", client_token(flags)) {
    Ok(payload) => payload
    Err(e) => fail("cluster status: \{e}")
  }
  let nodes = match @client.decode_nodes(nodes_payload) {
    Ok(nodes) => nodes
    Err(e) => fail("cluster status: \{e}")
  }
  let topics_payload = match
    control_call_with_token(
      remote,
      @client.CMD_TOPIC_LIST,
      b"",
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("cluster status: \{e}")
  }
  let topics = match @client.decode_wire_topics(topics_payload) {
    Ok(topics) => topics
    Err(e) => fail("cluster status: \{e}")
  }
  let online = nodes.length()
  println("nodes")
  for node in nodes {
    println(
      "  \{node.id}:\{@client.role_name(node.role)}	\{node.address}	leo=\{node.leo}",
    )
  }
  if online == 0 {
    println("  (none registered)")
  }
  println("topics")
  if topics.length() == 0 {
    println("  (none declared)")
  }
  for topic in topics {
    println(
      "  \{topic.name}	partitions=\{topic.partitions}	replication_factor=\{topic.replication_factor}",
    )
    // placement and watermarks per partition: what an operator
    // actually needs to answer "is this topic healthy?"
    for index in 0..<topic.partitions {
      let ref = @client.PartitionRef::{ topic: topic.name, partition: index }
      let view_payload = match
        control_call_with_token(
          remote,
          @client.CMD_LEADER,
          @client.encode_partition_ref(ref),
          client_token(flags),
        ) {
        Ok(payload) => payload
        Err(_) => continue
      }
      let view = match @client.decode_partition_view(view_payload) {
        Ok(view) => view
        Err(_) => continue
      }
      if view.leader.length() == 0 {
        let pending = if view.nominated.length() > 0 {
          ", election pending -> \{view.nominated}"
        } else {
          ""
        }
        println("    [\{index}] no leader\{pending}")
        continue
      }
      let offsets = match
        control_call_with_token(
          view.leader,
          @client.CMD_OFFSET_INFO,
          @client.encode_partition_ref(ref),
          client_token(flags),
        ) {
        Ok(payload) =>
          match @client.decode_offset_info(payload) {
            Ok(pair) => "hw=\{pair.0} leo=\{pair.1}"
            Err(_) => "hw=? leo=?"
          }
        Err(_) => "hw=? leo=? (leader unreachable)"
      }
      // who holds a partition, not just how many: an operator asking
      // "is this partition healthy?" needs to see which node to go
      // looking at (P7)
      println(
        "    [\{index}] leader=\{view.leader} replicas=\{format_addresses(view.replicas)} \{offsets}",
      )
    }
  }
  cli_exit(0)
}
