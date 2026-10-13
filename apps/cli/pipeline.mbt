// SPDX-License-Identifier: Apache-2.0
// pipeline: spec -> topology compilation, plan diff preview, apply
// (persist), run (in-process execution of the compiled topology).
//
// Applied state lives at <data-dir>/topology.json:
//   { "pipeline": "<name>", "spec": { ...the spec document... } }
// Compilation is pure and deterministic, so re-compiling the stored
// spec reproduces the applied topology exactly — nothing else needs
// persisting.

///|
fn cmd_pipeline(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    usage()
  }
  match argv[0] {
    "plan" => pipeline_plan(argv[1:argv.length()].to_owned())
    "apply" => pipeline_apply(argv[1:argv.length()].to_owned())
    "run" => pipeline_run(argv[1:argv.length()].to_owned())
    _ => usage()
  }
}

///|
const TOPOLOGY_FILE = "topology.json"

///|
struct Applied {
  pipeline : String
  spec : @spec.PipelineSpec
}

///|
fn topology_path(data_dir : String) -> String {
  "\{data_dir}/\{TOPOLOGY_FILE}"
}

///|
/// Loads the applied topology, if any. Missing file = never applied.
/// Corrupt or invalid applied state = fatal (plan cannot trust it).
fn load_applied(data_dir : String) -> Applied? {
  let path = topology_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    Ok(false) => return None
    Err(e) => fail("stat \{path}: \{e}")
  }
  let text = match @fs.read_file(path) {
    Ok(text) => text
    Err(e) => fail("read \{path}: \{e}")
  }
  let decoded = @utf8.decode_lossy(text[0:text.length()])
  let json = @json.parse(decoded[0:decoded.length()]) catch {
    _ => fail("corrupt \{path}: invalid json")
  }
  let name = match json.value("pipeline") {
    Some(String(name)) => name
    _ => fail("corrupt \{path}: missing pipeline name")
  }
  let spec_json = match json.value("spec") {
    Some(spec_json) => spec_json
    None => fail("corrupt \{path}: missing spec")
  }
  let spec_text = spec_json.stringify()
  match @spec.parse_spec(spec_text) {
    Ok(spec) => Some(Applied::{ pipeline: name, spec, })
    Err(errors) => {
      let sb = StringBuilder::new()
      sb.write_string("corrupt \{path}: stored spec no longer valid: ")
      for e in errors {
        sb.write_string("\{e.code} at \{e.path}; ")
      }
      fail(sb.to_string())
    }
  }
}

///|
/// Persists the compiled state: pipeline name + the spec document, and
/// the rule-asset revisions the apply resolved (the spec pins a *name*;
/// the topology records what that name meant at apply time, so drift
/// between a running pipeline and the store is visible).
fn persist_applied(
  data_dir : String,
  name : String,
  spec_json : Json,
  function_sets : Array[(String, Int64)],
  cluster_revision : Int64?,
) -> Result[Unit, String] {
  // Clock lives in the apps layer (kernel red line: core never reads
  // the wall clock); the timestamp records when apply compiled+saved.
  let doc_map : Map[String, Json] = {}
  doc_map["pipeline"] = Json::string(name)
  doc_map["applied_at"] = Json::number(
    @env.now().reinterpret_as_int64().to_double(),
  )
  let set_items : Array[Json] = []
  for pair in function_sets {
    let (set_name, revision) = pair
    let item : Map[String, Json] = {}
    item["name"] = Json::string(set_name)
    item["revision"] = Json::number(revision.to_double())
    set_items.push(Json::object(item))
  }
  doc_map["functions"] = Json::array(set_items)
  // which cluster revision this document came from (P11): absent for a
  // locally applied pipeline, which is not cluster-managed at all
  match cluster_revision {
    Some(revision) =>
      doc_map["cluster_revision"] = Json::number(revision.to_double())
    None => ()
  }
  doc_map["spec"] = spec_json
  let doc = Json::object(doc_map)
  let text = doc.stringify(indent=2)
  match @fs.mkdirs(data_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{data_dir}: \{e}")
  }
  match
    @fs.write_file(topology_path(data_dir), @utf8.encode(text[0:text.length()])) {
    Ok(_) => Ok(())
    Err(e) => Err("write topology: \{e}")
  }
}

///|
/// Reads and parses the spec document referenced by -f.
fn load_spec_doc(path : String) -> (@spec.PipelineSpec, Json) {
  let text = match @fs.read_file(path) {
    Ok(text) => text
    Err(e) => fail("read \{path}: \{e}")
  }
  let decoded = @utf8.decode_lossy(text[0:text.length()])
  let text = decoded[0:decoded.length()].to_owned()
  let json = @json.parse(text[0:text.length()]) catch {
    e => {
      println("error: \{path}: invalid json: \{e}")
      cli_exit(1)
      abort("unreachable")
    }
  }
  match @spec.parse_spec(text) {
    Ok(spec) => (spec, json)
    Err(errors) => {
      // spec rejections are diagnostics, and stdout carries the sink's data:
      // a pipeline whose spec was refused must not mix error text into the
      // stream a consumer is parsing by column (measured while gating the
      // callout's required `mode`: the refusal arrived on stdout)
      warn("error: \{path}: \{errors.length()} spec error(s):")
      for e in errors {
        warn("  \{e.path}: [\{e.code}] \{e.message}")
      }
      cli_exit(1)
      abort("unreachable")
    }
  }
}

///|
fn pipeline_plan(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let spec_path = flags.require("file")
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let (spec, _) = load_spec_doc(spec_path)
  let new_topology = @pipeline.compile(spec)
  let applied = load_applied(data_dir)
  let old : @pipeline.Topology? = match applied {
    Some(a) => Some(@pipeline.compile(a.spec))
    None => None
  }
  let ops = @pipeline.diff(old, new_topology)
  println("pipeline \{new_topology.pipeline} (spec \{spec_path})")
  println("processes:")
  for p in new_topology.processes {
    println("  \{p.name} [\{p.capability}] (\{p.role}): \{p.detail}")
  }
  match old {
    None => println("applied state: none (full create)")
    Some(t) => println("applied state: \{t.pipeline}")
  }
  println(@pipeline.render_diff(ops))
  cli_exit(0)
}

///|
fn pipeline_apply(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let spec_path = flags.require("file")
  // Two口径, deliberately separate: with --remote the pipeline becomes
  // the *cluster's* desired state (the control plane holds it and data
  // nodes pull); without it, this data dir applies to itself, which is
  // what a single-process broker has always done.
  if flags.get("remote") is Some(sc_addr) {
    let text = match @fs.read_file(spec_path) {
      Ok(bytes) => @utf8.decode_lossy(bytes[0:bytes.length()])
      Err(e) => fail("read \{spec_path}: \{e}")
    }
    let payload = match
      control_call_secure(
        sc_addr,
        @client.CMD_CLUSTER_PIPELINE_APPLY,
        @utf8.encode(text),
        peer_link(flags),
      ) {
      Ok(payload) => payload
      Err(e) => fail("pipeline apply: \{e}")
    }
    let pipeline = match @client.decode_cluster_pipeline(payload) {
      Ok(pipeline) => pipeline
      Err(e) => fail("pipeline apply: \{e}")
    }
    println(
      "applied pipeline to the cluster at revision \{pipeline.revision}; data nodes pull it on their next heartbeat",
    )
    cli_exit(0)
  }
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let (spec, spec_json) = load_spec_doc(spec_path)
  let new_topology = @pipeline.compile(spec)
  // publish-time static check: every transform must compile before
  // the topology is persisted (AGENTS §8) — bad rules never apply,
  // and a function-set reference that does not resolve is exactly
  // such a bad rule
  let store = file_metadata_store(data_dir)
  for t in spec.transforms {
    match compile_node(store, data_dir, t) {
      Ok(_) => ()
      Err(e) => fail("transform rejected: \{e}")
    }
  }
  let function_sets = match resolved_function_sets(spec, store) {
    Ok(sets) => sets
    Err(e) => fail("transform rejected: \{e}")
  }
  match
    persist_applied(
      data_dir,
      new_topology.pipeline,
      spec_json,
      function_sets,
      None,
    ) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  println(
    "applied pipeline \{new_topology.pipeline}: \{new_topology.processes.length()} processes -> \{topology_path(data_dir)}",
  )
  cli_exit(0)
}

///|

///|
/// How many records one read window of a topic source hands the chain. The
/// chain may split this further (the operator batch cap), and a window that
/// is too large would simply be a longer pause between sinks.
let topic_source_window : Int32 = 256

///|
/// How long a caught-up topic source waits before re-opening the log to look
/// for another process's appends. A follower's idle poll costs one tail scan
/// (recovery), so this is the knob that trades latency for CPU; 100ms is the
/// same order as the connectors' quiet poll.
fn topic_source_poll_ms() -> Int32 {
  match @env.get_env_var("MOONFLUX_TOPIC_POLL_MS") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => if n > 0 { n } else { DEFAULT_TOPIC_POLL_MS }
        Err(_) => DEFAULT_TOPIC_POLL_MS
      }
    None => DEFAULT_TOPIC_POLL_MS
  }
}

///|
const DEFAULT_TOPIC_POLL_MS : Int32 = 100

///|
/// Runs the consumption loop for a topic source: read from the pipeline's own
/// log at a cursor, apply the chain, deliver, advance by the last offset + 1
/// (P18's rule: records can be missing from a window, so counting records
/// would re-read).
///
/// It never reports Exhausted: catching up on a topic means "nothing new
/// right now", which is `Quiet` — the same three-state contract the
/// subscription sources follow (P19). A run therefore streams until it is
/// stopped, which is what a relay's second half has to do.
fn topic_source_loop(
  applied : Applied,
  sink : @connectors.Sink,
  chain : Array[CompiledNode],
  state : StateContext?,
  data_dir : String,
  from : String,
  resume : Bool,
) -> Unit {
  let name = applied.spec.topic.name
  let mut log = match open_topic_log_shared(data_dir, name) {
    Ok(log) => log
    Err(e) => fail("topic source \{name}: \{e}")
  }
  let mut cursor = match from {
    "beginning" => log.first_offset()
    "end" => log.high_watermark()
    _ => {
      // "offset:<n>" — normalized by the spec parser
      let text = from[7:from.length()].to_owned()
      match (try? @string.parse_int(text)) {
        Ok(n) => n.to_int64()
        Err(_) => fail("topic source: from=\"\{from}\" is not a position")
      }
    }
  }
  if resume {
    // The state topic is the truth about the state, and the marker is part of
    // it: "this state already reflects input up to offset N". A state replica
    // that LAGS its leader would carry an older marker and re-apply records
    // the state already absorbed — the boundary is written down in
    // docs/state-migration.md rather than hidden here.
    match state {
      Some(ctx) =>
        match ctx.progress() {
          Some(next) => {
            // stderr, not stdout: `pipeline run`'s stdout IS the sink's data
            // stream, so a diagnostic there is indistinguishable from a record
            // (measured: this line showed up in the middle of the output the
            // gate compares, and the gate could not find it where the rules
            // say diagnostics live)
            warn(
              "resuming at the offset the state recorded: \{next} (the spec says from=\{from})\n",
            )
            cursor = next
          }
          None =>
            warn(
              "the state topic holds no progress marker yet; starting at the declared from=\{from}\n",
            )
        }
      None => fail("--resume without a state context")
    }
  }
  while true {
    let end = log.high_watermark()
    if cursor >= end {
      // Caught up. The writer is another process, so this handle cannot
      // learn about new bytes: drop it and open again (see
      // open_topic_log_shared — a cached follower handle is the bug this
      // function exists to avoid).
      cli_sleep_ms(topic_source_poll_ms())
      log = match open_topic_log_shared(data_dir, name) {
        Ok(log) => log
        Err(e) => fail("topic source \{name}: \{e}")
      }
      continue
    }
    let entries = match log.read(cursor, topic_source_window) {
      Ok(entries) => entries
      Err(e) => fail("topic source \{name}: \{e}")
    }
    if entries.length() == 0 {
      cli_sleep_ms(50)
      continue
    }
    let pulled : Array[@protocol.Record] = []
    for entry in entries {
      pulled.push(entry.record)
    }
    let next_cursor = entries[entries.length() - 1].offset + 1
    // The progress marker is the RESUME feature's bookkeeping, so it exists
    // exactly when resume is in use: a plain run must not add a bookkeeping
    // key to the user's state topic. Measured — examples/sdf/16-word-probe's
    // expected state gained exactly one unexpected entry, and the example was
    // right: a run that never asked for continuity should not cause a key to
    // appear in the user's data.
    let progress = if resume { Some(next_cursor) } else { None }
    let out_records = match apply_nodes(chain, pulled, state, progress) {
      Ok(out) => out
      Err(e) => fail("transform: \{e}")
    }
    match (sink.flush)(out_records) {
      Ok(_) => ()
      Err(e) => fail("sink \{sink.name}: \{e}")
    }
    cursor = next_cursor
  }
}

///|
fn pipeline_run(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  // --spec runs a document directly (no applied state needed);
  // otherwise the applied topology supplies it
  let applied = match flags.get("spec") {
    Some(path) => {
      let (spec, _) = load_spec_doc(path)
      Applied::{ pipeline: spec.metadata_name, spec, }
    }
    None =>
      match load_applied(data_dir) {
        Some(applied) => applied
        None =>
          fail(
            "no applied pipeline under \{data_dir}; run: moonflux pipeline apply -f <spec> or pass --spec",
          )
      }
  }
  if flags.get("name") is Some(want) {
    if want != applied.pipeline {
      fail("applied pipeline is '\{applied.pipeline}', not '\{want}'")
    }
  }
  // dynamic rule chain: compiled once for this run (P1 capability),
  // with this data dir's function sets resolved for the referenced ones
  let store = file_metadata_store(data_dir)
  let chain : Array[CompiledNode] = []
  for t in applied.spec.transforms {
    match compile_node(store, data_dir, t) {
      Ok(node) => chain.push(node)
      Err(e) => fail("transform rejected: \{e}")
    }
  }
  // 1. source: pull until it is exhausted (P19). A one-shot source
  //    yields its records once and then says so; a subscription source
  //    says `Quiet` while it waits, and this loop keeps serving it —
  //    which is what makes `pipeline run` a connector process rather
  //    than a one-shot pass, without changing what one-shot sources do.
  let resume = flags.get("resume") is Some(_)
  if resume {
    // --resume means "continue where the state says it stopped", and only a
    // topic has offsets for the state to have recorded
    match applied.spec.source {
      TopicSource(_, _) => ()
      _ =>
        fail(
          "--resume needs a topic source: a file/http/stdin source has no offsets, so a restart cannot tell what the state already absorbed (declare \"type\": \"topic\")",
        )
    }
    match applied.spec.state {
      Some(_) => ()
      None =>
        fail(
          "--resume needs a state topic: the progress marker lives in the state, and this pipeline declares none",
        )
    }
  }
  let now = @env.now().reinterpret_as_int64()
  // A topic source is not a connector: the records already live in this
  // node's log, so there is nothing to pull from the outside world and
  // nothing to append (the parser requires the source to name this
  // pipeline's own topic, which is the topic the log below opens).
  let topic_source : String? = match applied.spec.source {
    TopicSource(_, from) => Some(from)
    _ => None
  }
  let source : @connectors.Source? = match applied.spec.source {
    TopicSource(_, _) => None
    FileSource(path) => Some(@connectors.file_source(path, now))
    HttpSource(url, interval_ms) =>
      Some(@connectors.http_source(url, now, interval_ms))
    StdinSource => Some(@connectors.stdin_source(now))
    MqttSource(url) => Some(@connectors.mqtt_source(url))
    KafkaSource(url) => Some(@connectors.kafka_source(url))
  }
  // 2. broker: append to the topic log
  let log = match open_topic_log(data_dir, applied.spec.topic.name) {
    Ok(log) => log
    Err(e) => fail(e)
  }
  // 3. the sink (constructed once: a streaming run flushes many batches)
  let sink = match applied.spec.sink {
    StdoutSink => @connectors.stdout_sink()
    HttpSink(url) => @connectors.http_sink(url)
    MqttSink(url) => @connectors.mqtt_sink(url)
    KafkaSink(url) => @connectors.kafka_sink(url)
    TopicSink(name) => {
      // the first half of a relay: the transformed batch lands in a topic
      // this node owns, and another pipeline can consume it
      let sink_log = match open_topic_log(data_dir, name) {
        Ok(log) => log
        Err(e) => fail("sink topic \{name}: \{e}")
      }
      @connectors.Sink::{
        name: "topic:\{name}",
        flush: fn(records) {
          if records.length() == 0 {
            return Ok(())
          }
          match sink_log.append(records) {
            Ok(_) => Ok(())
            Err(e) => Err("\{e}")
          }
        },
      }
    }
  }
  // 4. state (P30/T114): a pipeline that declares a state topic gets a
  // view of it, rebuilt by replay before the first batch. The topic is the
  // truth; the view is a cache (docs/operator-abi-v3-state.md).
  // --state-remote <sc>: state writes go to the cluster (the leader of the
  // state topic), so this node's data dir keeps its one-writer-per-partition
  // rule and the state topic replicates like any other topic (P36)
  let state_writer : ((Array[@protocol.Record]) -> Result[Unit, String])? = match
    flags.get("state-remote") {
    None => None
    Some(sc) => {
      let link = peer_link(flags)
      Some(fn(records) {
        let ref = @client.PartitionRef::{ topic: "", partition: 0, }
        let _ = ref
        match write_state_to_cluster(sc, topic_of(applied), records, link) {
          Ok(_) => Ok(())
          Err(e) => Err(e)
        }
      })
    }
  }
  let state = match applied.spec.state {
    None => None
    Some(topic) =>
      match StateContext::open(data_dir, topic, state_writer) {
        Ok(ctx) => Some(ctx)
        Err(e) => fail("state \{topic}: \{e}")
      }
  }
  match topic_source {
    Some(from) =>
      topic_source_loop(applied, sink, chain, state, data_dir, from, resume)
    None => ()
  }
  let source = match source {
    Some(source) => source
    None => fail("a topic source has no connector to pull from")
  }
  while true {
    let pull = match (source.pull)() {
      Ok(pull) => pull
      Err(e) => fail("source \{source.name}: \{e}")
    }
    match pull {
      Exhausted => break
      Quiet => cli_sleep_ms(50)
      Records(records) =>
        if records.length() == 0 {
          // a pull with nothing in it is a quiet poll wearing a data
          // shape: sleep like one, don't spin
          cli_sleep_ms(50)
        } else {
          let base = match log.append(records) {
            Ok(base) => base
            Err(e) => fail("append: \{e}")
          }
          // dynamic rules on the consumption path, then the sink.
          // The chain runs over the WHOLE pulled batch: mbel nodes
          // filter per record, and batch-shaped nodes (wasm operators,
          // v2 scalar ceilings) get the batch they were designed for —
          // a per-record loop used to hand a wasm operator envelopes
          // of one record and made a per-batch ceiling unenforceable
          // (P26 found both by writing the ceiling's gate).
          let entries = match log.read(base, records.length()) {
            Ok(entries) => entries
            Err(e) => fail("read: \{e}")
          }
          let pulled : Array[@protocol.Record] = []
          for entry in entries {
            pulled.push(entry.record)
          }
          let out_records = match apply_nodes(chain, pulled, state, None) {
            Ok(out) => out
            Err(e) => fail("transform: \{e}")
          }
          match (sink.flush)(out_records) {
            Ok(_) => ()
            Err(e) => fail("sink \{sink.name}: \{e}")
          }
        }
    }
  }
  cli_exit(0)
}

///|
/// The state topic's name, or "" when the spec declares none. Split out so the
/// remote-state closure does not capture the whole spec.
fn topic_of(applied : Applied) -> String {
  match applied.spec.state {
    Some(topic) => topic
    None => ""
  }
}

///|
/// Appends a state batch to the CLUSTER: resolve the state topic's leader
/// through the control plane, then produce the batch there (one frame, one
/// append — the node owns the log and its cache stays honest).
///
/// A leader that moves between the resolve and the send is an ordinary race:
/// the produce is refused with the new leader's address, the batch is not
/// written, and the run fails loudly rather than writing to a follower.
fn write_state_to_cluster(
  sc : String,
  topic : String,
  records : Array[@protocol.Record],
  link : PeerLink,
) -> Result[Unit, String] {
  if topic.length() == 0 {
    return Err("--state-remote without a state topic")
  }
  let payload = match
    control_call_secure(
      sc,
      @client.CMD_LEADER,
      @client.encode_partition_ref(@client.PartitionRef::{
        topic,
        partition: 0,
      }),
      link,
    ) {
    Ok(payload) => payload
    Err(e) => return Err("state leader lookup: \{e}")
  }
  let view = match @client.decode_partition_view(payload) {
    Ok(view) => view
    Err(e) => return Err("state leader lookup: \{e}")
  }
  if view.leader.length() == 0 {
    return Err(
      "the state topic \{topic}[0] has no leader yet; refusing to write state nowhere",
    )
  }
  let (host, port) = parse_listen_addr(view.leader)
  let producer = match
    connect_producer_transport(host, port, link.token, link.tls) {
    Ok(producer) => producer
    Err(e) => return Err("state produce connect \{view.leader}: \{e}")
  }
  let sent = producer.send(topic, records)
  producer.close()
  match sent {
    Ok(_) => Ok(())
    Err(e) => Err("state produce: \{e}")
  }
}
