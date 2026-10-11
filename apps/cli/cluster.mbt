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
    "compact" => cluster_compact(rest)
    "spu" => cluster_spu_list(rest)
    "metadata" => cluster_metadata(rest)
    _ =>
      fail(
        "cluster: unknown verb '\{verb}' (known: nodes, status, leader, offsets, segments, compact, spu, metadata)",
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
  // a control plane must be asked, not guessed: explicit --remote or a
  // current profile (resolve_remote's refusal names both ways)
  let remote = resolve_remote(flags)
  let payload = match
    control_call_secure(remote, @client.CMD_NODES, b"", peer_link(flags)) {
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
  let remote = resolve_remote(flags)
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  let ref = @client.PartitionRef::{ topic, partition, }
  let payload = match
    control_call_secure(
      remote,
      @client.CMD_LEADER,
      @client.encode_partition_ref(ref),
      peer_link(flags),
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
  let remote = resolve_remote(flags)
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
    control_call_secure(remote, @client.CMD_OFFSET_INFO, ask, peer_link(flags)) {
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
/// `moonflux cluster compact --topic T [--partition N] --remote <leader>`
/// — one keyed-compaction pass (P14): every record below the committed
/// floor whose key occurs again below it is dropped, and the survivors
/// keep their offsets. Asked of a node that hosts the partition: every
/// replica compacts its own copy — the copies must agree about what a
/// keyed log contains, or a failover would resurrect deleted keys.
/// Prints one line per rewritten segment (base, frames before/after,
/// records dropped, bytes before/after) and a summary line; the floor
/// itself is the node's to compute, from its committed prefix lowered
/// by the groups' floors — the same number retention uses. Every
/// replica of the partition is compacted with its own copy in mind (the
/// copies must agree about a keyed log), so point this at each node
/// that hosts it, not only the leader.
fn cluster_compact(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = resolve_remote(flags)
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  let ref = @client.PartitionRef::{ topic, partition, }
  let payload = match
    control_call_secure(
      remote,
      @client.CMD_COMPACT,
      @client.encode_partition_ref(ref),
      peer_link(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("cluster compact: \{e}")
  }
  let rewritten = match @client.decode_wire_compactions(payload) {
    Ok(entries) => entries
    Err(e) => fail("cluster compact: \{e}")
  }
  let mut dropped = 0
  let mut freed = 0
  for seg in rewritten {
    dropped += seg.dropped_records
    freed += seg.bytes_before - seg.bytes_after
    println(
      "\{seg.base}\t\{seg.frames_before}\t\{seg.frames_after}\t\{seg.dropped_records}\t\{seg.bytes_before}\t\{seg.bytes_after}",
    )
  }
  println(
    "compacted \{rewritten.length()} segment(s) of \{topic}[\{partition}]: \{dropped} records dropped, \{freed} bytes freed",
  )
  cli_exit(0)
}

///|
/// `moonflux cluster segments --topic T [--partition N] --remote <node>`
/// — the partition's segments, oldest first: which offsets each covers
/// and how many bytes it costs. Asked of the node that holds the
/// partition, because the disk is that node's fact (P8).
fn cluster_segments(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = resolve_remote(flags)
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) => parse_partition_flag(text)
    None => 0
  }
  let ref = @client.PartitionRef::{ topic, partition, }
  let payload = match
    control_call_secure(
      remote,
      @client.CMD_SEGMENTS,
      @client.encode_partition_ref(ref),
      peer_link(flags),
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
  let remote = resolve_remote(flags)
  let nodes_payload = match
    control_call_secure(remote, @client.CMD_NODES, b"", peer_link(flags)) {
    Ok(payload) => payload
    Err(e) => fail("cluster status: \{e}")
  }
  let nodes = match @client.decode_nodes(nodes_payload) {
    Ok(nodes) => nodes
    Err(e) => fail("cluster status: \{e}")
  }
  let topics_payload = match
    control_call_secure(remote, @client.CMD_TOPIC_LIST, b"", peer_link(flags)) {
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
      let ref = @client.PartitionRef::{ topic: topic.name, partition: index, }
      let view_payload = match
        control_call_secure(
          remote,
          @client.CMD_LEADER,
          @client.encode_partition_ref(ref),
          peer_link(flags),
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
        control_call_secure(
          view.leader,
          @client.CMD_OFFSET_INFO,
          @client.encode_partition_ref(ref),
          peer_link(flags),
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

///|
/// `moonflux partition list --topic T --remote <control plane | serve>`
/// — the per-partition observability face (cli-roadmap §3.3, the
/// reference's `partition list`): one flat row per partition with who
/// leads it, who holds it, and how far it has come. A composition of
/// the same three questions `cluster status` asks, narrowed to one
/// topic; it works against a serve as well, because a standalone
/// broker answers LEADER for everything it hosts (P22).
fn partition_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = resolve_remote(flags)
  let topic = flags.require("topic")
  let link = peer_link(flags)
  let topics_payload = match
    control_call_secure(remote, @client.CMD_TOPIC_LIST, b"", link) {
    Ok(payload) => payload
    Err(e) => fail("partition list: \{e}")
  }
  let topics = match @client.decode_wire_topics(topics_payload) {
    Ok(topics) => topics
    Err(e) => fail("partition list: \{e}")
  }
  let mut count = -1
  for candidate in topics {
    if candidate.name == topic {
      count = candidate.partitions
    }
  }
  if count < 0 {
    fail(
      "partition list: topic \{topic} is not declared or hosted there (topic list shows what exists)",
    )
  }
  println("partition\tleader\treplicas\thw\tleo")
  for index in 0..<count {
    let ref = @client.PartitionRef::{ topic, partition: index, }
    let (leader, replicas) = match
      control_call_secure(
        remote,
        @client.CMD_LEADER,
        @client.encode_partition_ref(ref),
        link,
      ) {
      Ok(payload) =>
        match @client.decode_partition_view(payload) {
          Ok(view) =>
            if view.leader.length() == 0 {
              ("(election pending)", format_addresses(view.replicas))
            } else {
              (view.leader, format_addresses(view.replicas))
            }
          Err(_) => ("?", "?")
        }
      Err(_) => ("?", "?")
    }
    let (hw, leo) = if leader.length() == 0 ||
      leader == "?" ||
      leader == "(election pending)" {
      ("?", "?")
    } else {
      match
        control_call_secure(
          leader,
          @client.CMD_OFFSET_INFO,
          @client.encode_partition_ref(ref),
          link,
        ) {
        Ok(payload) =>
          match @client.decode_offset_info(payload) {
            Ok(pair) => (pair.0.to_string(), pair.1.to_string())
            Err(_) => ("?", "?")
          }
        Err(_) => ("?", "?")
      }
    }
    println("\{index}\t\{leader}\t\{replicas}\t\{hw}\t\{leo}")
  }
  cli_exit(0)
}

///|
/// `moonflux cluster spu list --remote <control plane>` — the nodes as
/// the control plane sees them, with what each one holds: the
/// registered set (id, address, role, log end) joined with the
/// placement views into per-node hosting counts. Composed client-side
/// from answers the control plane already serves; a per-node disk-byte
/// total would need the nodes to report it, which is a protocol
/// addition, not a query (left out rather than approximated).
fn cluster_spu_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = resolve_remote(flags)
  let link = peer_link(flags)
  let nodes_payload = match
    control_call_secure(remote, @client.CMD_NODES, b"", link) {
    Ok(payload) => payload
    Err(e) => fail("cluster spu list: \{e}")
  }
  let nodes = match @client.decode_nodes(nodes_payload) {
    Ok(nodes) => nodes
    Err(e) => fail("cluster spu list: \{e}")
  }
  let topics_payload = match
    control_call_secure(remote, @client.CMD_TOPIC_LIST, b"", link) {
    Ok(payload) => payload
    Err(e) => fail("cluster spu list: \{e}")
  }
  let topics = match @client.decode_wire_topics(topics_payload) {
    Ok(topics) => topics
    Err(e) => fail("cluster spu list: \{e}")
  }
  let hosted : Map[String, Int] = {}
  let topic_names : Map[String, Map[String, Bool]] = {}
  for topic in topics {
    for index in 0..<topic.partitions {
      let ref = @client.PartitionRef::{ topic: topic.name, partition: index, }
      let view = match
        control_call_secure(
          remote,
          @client.CMD_LEADER,
          @client.encode_partition_ref(ref),
          link,
        ) {
        Ok(payload) =>
          match @client.decode_partition_view(payload) {
            Ok(view) => view
            Err(_) => continue
          }
        Err(_) => continue
      }
      for address in view.replicas {
        let seen = match hosted.get(address) {
          Some(count) => count
          None => 0
        }
        hosted[address] = seen + 1
        match topic_names.get(address) {
          Some(set) => set[topic.name] = true
          None => {
            let set : Map[String, Bool] = {}
            set[topic.name] = true
            topic_names[address] = set
          }
        }
      }
    }
  }
  println("spu\taddress\trole\tleo\thosted-partitions\ttopics")
  for node in nodes {
    let held = match hosted.get(node.address) {
      Some(count) => count
      None => 0
    }
    let topic_count = match topic_names.get(node.address) {
      Some(set) => set.length()
      None => 0
    }
    println(
      "\{node.id}\t\{node.address}\t\{@client.role_name(node.role)}\t\{node.leo}\t\{held}\t\{topic_count}",
    )
  }
  cli_exit(0)
}

///|
/// `moonflux partition <verb>` — the partition observability family.
fn cmd_partition(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("partition: missing verb (list)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "list" => partition_list(rest)
    _ => fail("partition: unknown verb '\{verb}' (known: list)")
  }
}

///|
/// `moonflux cluster metadata <verb>` — the control plane's OWN document,
/// from the command line. `backup`/`restore` are the answer to the largest
/// risk in docs/production-readiness.md §3: the control plane keeps its
/// declarations in one file, and a corrupt or lost file means lost topics.
///
/// The snapshot is a plain JSON document, so it is portable off the host —
/// that is the point. It carries a CRC-32C over the metadata text so a
/// truncated copy is refused by name instead of restoring silently half a
/// cluster. CRC detects corruption, NOT tampering: an attacker who can
/// rewrite the snapshot can rewrite the checksum, and this is stated rather
/// than implied (the threat model of a backup file is the filesystem's).
fn cluster_metadata(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("cluster metadata: missing verb (show|backup|restore)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "show" => cluster_metadata_show(rest)
    "backup" => cluster_metadata_backup(rest)
    "restore" => cluster_metadata_restore(rest)
    _ =>
      fail(
        "cluster metadata: unknown verb '\{verb}' (known: show, backup, restore)",
      )
  }
}

///|
/// How a snapshot document declares itself. A restore that does not check
/// this would happily read someone else's JSON (a spec, a cassette, a
/// metrics dump) and write it as cluster state.
const METADATA_SNAPSHOT_KIND : String = "moonflux.metadata-snapshot"

///|
/// The snapshot format's own version, separate from the metadata revision:
/// the format can change without the cluster's revision meaning anything
/// different.
const METADATA_SNAPSHOT_VERSION : Int = 1

///|
fn cluster_metadata_show(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let store = file_metadata_store(data_dir)
  let metadata = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => fail("cluster metadata show: \{json_error_text(e)}")
  }
  if flags.get("json") is Some(_) {
    println(encode_metadata_doc(metadata).stringify(indent=2))
    return
  }
  println("data dir    \{data_dir}")
  println("revision    \{metadata.version}")
  println("topics      \{metadata.topics.length()}")
  for topic in metadata.topics {
    println(
      "  \{topic.name}\tpartitions=\{topic.partitions}\trf=\{topic.replication_factor}",
    )
  }
  println("function sets \{metadata.function_sets.length()}")
  for set in metadata.function_sets {
    println("  \{set.name}\trevision=\{set.revision}")
  }
}

///|
/// The metadata document as JSON — one encoder for both the store's file and
/// a snapshot's payload, so a backup cannot be a slightly different shape
/// from the thing it backs up.
pub fn encode_metadata_doc(metadata : ClusterMetadata) -> Json {
  let items : Array[Json] = []
  for topic in metadata.topics {
    let doc : Map[String, Json] = {}
    doc["name"] = Json::string(topic.name)
    doc["partitions"] = Json::number(topic.partitions.to_double())
    doc["replication_factor"] = Json::number(
      topic.replication_factor.to_double(),
    )
    items.push(Json::object(doc))
  }
  let set_items : Array[Json] = []
  for set in metadata.function_sets {
    set_items.push(encode_function_set_doc(set))
  }
  let root : Map[String, Json] = {}
  root["version"] = Json::number(metadata.version.to_double())
  root["topics"] = Json::array(items)
  root["function_sets"] = Json::array(set_items)
  Json::object(root)
}

///|
fn cluster_metadata_backup(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let out = flags.require("out")
  let store = file_metadata_store(data_dir)
  let metadata = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) =>
      fail(
        "cluster metadata backup: refusing to snapshot a store that does not load: \{json_error_text(e)}",
      )
  }
  let payload = encode_metadata_doc(metadata).stringify(indent=2)
  let checksum = @codec.crc32c(@utf8.encode(payload))
  let root : Map[String, Json] = {}
  root["kind"] = Json::string(METADATA_SNAPSHOT_KIND)
  root["snapshot_version"] = Json::number(METADATA_SNAPSHOT_VERSION.to_double())
  root["taken_from"] = Json::string(data_dir)
  root["revision"] = Json::number(metadata.version.to_double())
  root["checksum"] = Json::string(checksum.to_string())
  root["metadata"] = @json.parse(payload[0:payload.length()]) catch {
    e => fail("cluster metadata backup: cannot re-read its own encoding: \{e}")
  }
  let text = Json::object(root).stringify(indent=2)
  match @fs.write_file(out, @utf8.encode(text[0:text.length()])) {
    Ok(_) => ()
    Err(e) => fail("cluster metadata backup: write \{out}: \{e}")
  }
  note(
    "wrote \{out}: revision \{metadata.version}, \{metadata.topics.length()} topic declaration(s), \{metadata.function_sets.length()} function set(s), crc32c \{checksum}",
  )
}

///|
fn cluster_metadata_restore(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let input = flags.require("in")
  let force = flags.get("force") is Some(_)
  let bytes = match @fs.read_file(input) {
    Ok(bytes) => bytes
    Err(e) => fail("cluster metadata restore: read \{input}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => fail("cluster metadata restore: \{input} is not valid JSON: \{e}")
  }
  let root = match json {
    Object(obj) => obj
    _ => fail("cluster metadata restore: \{input} must be a JSON object")
  }
  match root.get("kind") {
    Some(String(kind)) =>
      if kind != METADATA_SNAPSHOT_KIND {
        fail(
          "cluster metadata restore: \{input} is a '\{kind}', not a '\{METADATA_SNAPSHOT_KIND}'",
        )
      }
    _ =>
      fail(
        "cluster metadata restore: \{input} has no kind; expected '\{METADATA_SNAPSHOT_KIND}'",
      )
  }
  match root.get("snapshot_version") {
    Some(Number(n)) =>
      if n.to_int() != METADATA_SNAPSHOT_VERSION {
        fail(
          "cluster metadata restore: snapshot format version \{n.to_int()} is not \{METADATA_SNAPSHOT_VERSION}",
        )
      }
    _ =>
      fail(
        "cluster metadata restore: \{input} has no snapshot_version; expected \{METADATA_SNAPSHOT_VERSION}",
      )
  }
  let payload_json = match root.get("metadata") {
    Some(metadata) => metadata
    None => fail("cluster metadata restore: \{input} has no metadata payload")
  }
  let payload = payload_json.stringify(indent=2)
  let claimed = match root.get("checksum") {
    Some(String(text)) => text
    _ => fail("cluster metadata restore: \{input} has no checksum")
  }
  let actual = @codec.crc32c(@utf8.encode(payload)).to_string()
  if claimed != actual {
    fail(
      "cluster metadata restore: checksum mismatch (snapshot says \{claimed}, the payload is \{actual}); the file is corrupt",
    )
  }
  // the payload is written through the store's own decoder: a snapshot is
  // not a second format, it is the same document with an envelope
  let store = file_metadata_store(data_dir)
  let local = match (store.load)() {
    Ok(local) => local
    Err(e) =>
      fail(
        "cluster metadata restore: local store does not load: \{json_error_text(e)}",
      )
  }
  let restored = match decode_metadata_doc(payload_json) {
    Ok(metadata) => metadata
    Err(e) => fail("cluster metadata restore: \{json_error_text(e)}")
  }
  if restored.version < local.version && !force {
    fail(
      "cluster metadata restore: the snapshot is at revision \{restored.version}, this node is at \{local.version}; restoring would go backwards (pass --force to discard the newer local declarations)",
    )
  }
  // the restore is itself a write, so the result is a NEW revision: a
  // running control plane that saw revision N must not see it go back to N-1
  let base_version = if restored.version > local.version {
    restored.version
  } else {
    local.version
  }
  let next_version = base_version + 1L
  let applied = ClusterMetadata::{
    topics: restored.topics,
    function_sets: restored.function_sets,
    version: next_version,
  }
  match (store.save)(applied) {
    Ok(_) => ()
    Err(e) => fail("cluster metadata restore: save: \{json_error_text(e)}")
  }
  note(
    "restored \{applied.topics.length()} topic declaration(s) and \{applied.function_sets.length()} function set(s) into \{data_dir}: revision \{local.version} -> \{applied.version}",
  )
}

///|
/// The metadata document decoder, shared with the store's file reader so a
/// snapshot cannot be accepted with a shape the store would reject.
pub fn decode_metadata_doc(
  json : Json,
) -> Result[ClusterMetadata, MetadataError] {
  let obj = match json {
    Object(obj) => obj
    _ => return Err(Corrupt("metadata must be a JSON object"))
  }
  let version = match obj.get("version") {
    Some(Number(n)) => n.to_int64()
    _ => 0L
  }
  let topics : Array[ClusterMetadataTopic] = []
  match obj.get("topics") {
    Some(Array(items)) =>
      for item in items {
        match decode_topic_doc(item) {
          Ok(topic) => topics.push(topic)
          Err(e) => return Err(e)
        }
      }
    Some(_) => return Err(Corrupt("topics must be an array"))
    None => ()
  }
  let function_sets : Array[ClusterMetadataFunctionSet] = []
  match obj.get("function_sets") {
    Some(Array(items)) =>
      for item in items {
        match decode_function_set_doc(item) {
          Ok(set) => function_sets.push(set)
          Err(e) => return Err(e)
        }
      }
    Some(_) => return Err(Corrupt("function_sets must be an array"))
    None => ()
  }
  Ok(ClusterMetadata::{ topics, function_sets, version, })
}

///|
/// The one place a MetadataError becomes text a person reads. The store's
/// own variants already say what is wrong; this only keeps the CLI's
/// messages uniform.
pub fn json_error_text(e : MetadataError) -> String {
  match e {
    Corrupt(msg) => "corrupt: \{msg}"
    Conflict(msg) => "conflict: \{msg}"
    Storage(msg) => "storage: \{msg}"
    Rejected(msg) => "rejected: \{msg}"
  }
}
