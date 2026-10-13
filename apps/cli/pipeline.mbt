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
    "view" => pipeline_view(argv[1:argv.length()].to_owned())
    "apply" => pipeline_apply(argv[1:argv.length()].to_owned())
    "delete" => pipeline_delete(argv[1:argv.length()].to_owned())
    "list" => pipeline_list(argv[1:argv.length()].to_owned())
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
  // P37: the applied state is a SET of tasks now. This compat reader answers
  // "which single pipeline is this data dir about" for the callers that only
  // need one (the plan diff, the node's compat LEO field, self-placement):
  // the FIRST task in name order. Anything that must see every task uses
  // `load_task_set` directly.
  let set = load_task_set(data_dir)
  if set.tasks.length() == 0 {
    return None
  }
  let first = set.tasks[0]
  Some(Applied::{ pipeline: first.name, spec: first.spec, })
}

///|
/// Persists ONE task as the whole set. This is the old single-pipeline writer
/// kept for the paths that legitimately replace everything (the cluster
/// adoption path writes the control plane's document; `--set` writes the
/// operator's set). Upsert lives in `pipeline_apply`, which must preserve the
/// sibling tasks' stored JSON.
fn persist_applied(
  data_dir : String,
  name : String,
  spec_json : Json,
  function_sets : Array[(String, Int64)],
  cluster_revision : Int64?,
) -> Result[Unit, String] {
  let task = task_json(
    name,
    spec_json,
    function_sets,
    @env.now().reinterpret_as_int64(),
  )
  write_task_set(data_dir, [task], cluster_revision)
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
  // diff against the task of the SAME NAME in the applied set (P37):
  // planning task B must not be diffed against task A
  let applied = load_task_set(data_dir).find(new_topology.pipeline)
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
/// `pipeline view -f spec.json`: the compiled topology as the console's view
/// model (nodes + edges), printed as JSON.
///
/// It exists so the model has a SECOND reader beside the browser: the gate
/// compares this output with the editor kernel's, which is the P37-3 claim
/// ("the page and the CLI show the same graph") turned into a byte comparison.
fn pipeline_view(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let spec_path = flags.require("file")
  let (spec, _) = load_spec_doc(spec_path)
  println(@pipeline.view_model_text(spec, @pipeline.compile(spec)))
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
    // Which of the three shapes the operator meant travels WITH the document
    // (P37): a control plane must never have to guess whether "apply" means
    // "add this task" or "this is now the whole cluster's task list".
    let mode = if flags.get("set") is Some(_) {
      "set"
    } else if flags.get("replace") is Some(_) {
      "replace"
    } else {
      "upsert"
    }
    let envelope : Map[String, Json] = {}
    envelope["mode"] = Json::string(mode)
    envelope["document"] = Json::string(text)
    let body = Json::object(envelope).stringify()
    let payload = match
      control_call_secure(
        sc_addr,
        @client.CMD_CLUSTER_PIPELINE_APPLY,
        @utf8.encode(body),
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
      "\{mode} published to the cluster at revision \{pipeline.revision}; data nodes pull the whole task set on their next heartbeat",
    )
    cli_exit(0)
  }
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let store = file_metadata_store(data_dir)
  let existing = load_task_set(data_dir)
  let now = @env.now().reinterpret_as_int64()
  // Two shapes of input, deliberately different:
  //   (default) one spec  -> UPSERT by metadata.name, siblings preserved
  //   --set               -> a set document replaces the whole set
  // The distinction matters because the first is what an operator does to a
  // task and the second is what an operator does to a catalog.
  let (tasks, message) = if flags.get("set") is Some(_) {
    let incoming = load_set_doc(spec_path)
    let prepared : Array[TaskDoc] = []
    for doc in incoming {
      prepared.push(prepare_stored_task(store, data_dir, doc, now))
    }
    (prepared, "applied \{prepared.length()} task(s) as the whole set")
  } else {
    let (spec, spec_json) = load_spec_doc(spec_path)
    let topology = @pipeline.compile(spec)
    let task = prepare_task(
      store,
      data_dir,
      topology.pipeline,
      spec,
      spec_json,
      now,
    )
    // --replace: this one spec IS the whole set. That was the meaning of
    // `apply` before P37, so it stays available — explicitly, because
    // "upsert one task" and "this is the entire set" are different actions
    // and a tool that cannot say which it means will do the wrong one.
    if flags.get("replace") is Some(_) {
      (
        [task],
        "replaced the set with task \{topology.pipeline}: \{topology.processes.length()} processes",
      )
    } else {
      let merged : Array[TaskDoc] = []
      let mut replaced = false
      for t in existing.tasks {
        if t.name == task.name {
          merged.push(task)
          replaced = true
        } else {
          merged.push(t)
        }
      }
      if !replaced {
        merged.push(task)
      }
      let verb = if replaced { "updated" } else { "added" }
      (
        merged,
        "\{verb} task \{topology.pipeline}: \{topology.processes.length()} processes, \{merged.length()} task(s) in the set",
      )
    }
  }
  match validate_tasks(tasks, data_dir) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let jsons : Array[Json] = []
  for t in tasks {
    jsons.push(t.json)
  }
  // a LOCAL apply is not the cluster's document, so the cluster revision is
  // dropped: on a cluster-managed node the control plane's set is adopted
  // again on the next heartbeat (use `--remote` to change the cluster's
  // desired state — documented, and the gate shows the behaviour)
  match write_task_set(data_dir, jsons, None) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  println("\{message} -> \{topology_path(data_dir)}")
  cli_exit(0)
}

///|
/// Publish-time checks for one task (AGENTS §8): every transform must compile
/// against THIS data dir's function sets before anything is stored, and the
/// function-set revisions the spec resolved are recorded with it. Bad rules
/// never apply.
fn prepare_task(
  store : MetadataStore,
  data_dir : String,
  name : String,
  spec : @spec.PipelineSpec,
  spec_json : Json,
  now : Int64,
) -> TaskDoc {
  for t in spec.transforms {
    match compile_node(store, data_dir, t) {
      Ok(_) => ()
      Err(e) => fail("task \{name}: transform rejected: \{e}")
    }
  }
  let function_sets = match resolved_function_sets(spec, store) {
    Ok(sets) => sets
    Err(e) => fail("task \{name}: transform rejected: \{e}")
  }
  TaskDoc::{ name, spec, json: task_json(name, spec_json, function_sets, now), }
}

///|
/// Publish-time checks for a task that already has its STORED shape (an import
/// through `--set`): compile every transform against this data dir's function
/// sets, and re-derive the function-set revisions the spec resolves. The spec
/// DOCUMENT lives inside the stored object's `spec` field — handing the object
/// itself to `prepare_task` would store a task object as if it were a spec
/// document, which the reader then refuses (measured: "stored spec for task-a
/// no longer valid: unknown-field at $.pipeline").
fn prepare_stored_task(
  store : MetadataStore,
  data_dir : String,
  doc : TaskDoc,
  now : Int64,
) -> TaskDoc {
  let spec_json = match doc.json.value("spec") {
    Some(spec_json) => spec_json
    None => fail("task \{doc.name}: the set document has no spec for it")
  }
  for t in doc.spec.transforms {
    match compile_node(store, data_dir, t) {
      Ok(_) => ()
      Err(e) => fail("task \{doc.name}: transform rejected: \{e}")
    }
  }
  let function_sets = match resolved_function_sets(doc.spec, store) {
    Ok(sets) => sets
    Err(e) => fail("task \{doc.name}: transform rejected: \{e}")
  }
  TaskDoc::{
    name: doc.name,
    spec: doc.spec,
    json: task_json(doc.name, spec_json, function_sets, now),
  }
}

///|
/// Reads a `--set` document: `{"pipelines": [...]}` where each element is
/// either a stored task object or a bare spec document (both accepted, so a
/// catalog round-trips). The parsing itself lives with the task-set layer, so
/// the CLI and the control plane cannot drift on what a set document is.
fn load_set_doc(path : String) -> Array[TaskDoc] {
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => fail("read \{path}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  match task_docs_from_set_text(text, path) {
    Ok(docs) => docs
    Err(e) => fail(e)
  }
}

///|
/// `pipeline delete --name X [--data-dir D]`: removes one task, refusing a
/// name that is not there (a delete that silently does nothing hides typos).
fn pipeline_delete(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let name = flags.require("name")
  if flags.get("remote") is Some(sc_addr) {
    let payload = match
      control_call_secure(
        sc_addr,
        @client.CMD_CLUSTER_PIPELINE_DELETE,
        @utf8.encode(name),
        peer_link(flags),
      ) {
      Ok(payload) => payload
      Err(e) => fail("pipeline delete: \{e}")
    }
    let pipeline = match @client.decode_cluster_pipeline(payload) {
      Ok(pipeline) => pipeline
      Err(e) => fail("pipeline delete: \{e}")
    }
    println(
      "deleted task \{name} on the cluster (now revision \{pipeline.revision}); data nodes pull the new set on their next heartbeat",
    )
    cli_exit(0)
  }
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let set = load_task_set(data_dir)
  if set.find(name) is None {
    let known = if set.tasks.length() == 0 {
      "none"
    } else {
      task_names(set).join(", ")
    }
    fail("no task named \{name} under \{data_dir} (tasks: \{known})")
  }
  let kept : Array[Json] = []
  for t in set.tasks {
    if t.name != name {
      kept.push(t.json)
    }
  }
  match write_task_set(data_dir, kept, None) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  println("deleted task \{name} (\{kept.length()} task(s) left)")
  cli_exit(0)
}

///|
/// `pipeline list [--data-dir D | --remote SC]`: the task set, one tab
/// separated line per task (the shape `topic list` uses, so `cut -f1` works).
fn pipeline_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  if flags.get("remote") is Some(sc_addr) {
    // a non-empty payload asks the control plane for the DOCUMENT (the empty
    // one asks only for the revision number)
    let payload = match
      control_call_secure(
        sc_addr,
        @client.CMD_CLUSTER_PIPELINE_FETCH,
        @utf8.encode("get"),
        peer_link(flags),
      ) {
      Ok(payload) => payload
      Err(e) => fail("pipeline list: \{e}")
    }
    let pipeline = match @client.decode_cluster_pipeline(payload) {
      Ok(pipeline) => pipeline
      Err(e) => fail("pipeline list: \{e}")
    }
    if pipeline.document.length() == 0 {
      println("no task is applied on this cluster")
      cli_exit(0)
    }
    let set = match
      parse_task_set_text(pipeline.document, "the cluster's task set") {
      Ok(set) => set
      Err(e) => fail(e)
    }
    for line in task_list_lines(set) {
      println(line)
    }
    println("cluster_revision=\{pipeline.revision}")
    cli_exit(0)
  }
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let set = load_task_set(data_dir)
  if set.tasks.length() == 0 {
    println("no task applied under \{data_dir}")
    cli_exit(0)
  }
  for line in task_list_lines(set) {
    println(line)
  }
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
  session : RunSession?,
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
    // the batch is the run's own record, and the report rides it (P37-2)
    match session {
      Some(run) => run.batch(next_cursor, now_ms())
      None => ()
    }
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
    None => {
      let set = load_task_set(data_dir)
      let known = if set.tasks.length() == 0 {
        "none"
      } else {
        task_names(set).join(", ")
      }
      if set.tasks.length() == 0 {
        fail(
          "no applied pipeline under \{data_dir}; run: moonflux pipeline apply -f <spec> or pass --spec",
        )
      }
      match flags.get("name") {
        Some(want) =>
          match set.find(want) {
            Some(task) => Applied::{ pipeline: task.name, spec: task.spec, }
            None =>
              fail("no task named \{want} under \{data_dir} (tasks: \{known})")
          }
        None =>
          if set.tasks.length() == 1 {
            let task = set.tasks[0]
            Applied::{ pipeline: task.name, spec: task.spec, }
          } else {
            fail(
              "the applied set has \{set.tasks.length()} tasks (\{known}); pass --name <task>",
            )
          }
      }
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
  // ---------------------------------------------------------------
  // The run's own record (P37-2). A run registers only when it was TOLD where
  // to report (`--control`, or the cluster its state already goes through):
  // adding a run-log topic to someone's data dir unasked is the mistake the
  // state progress marker made in P36, and the example gate caught it then.
  let control : String? = match flags.get("control") {
    Some(addr) => Some(addr)
    None => flags.get("state-remote")
  }
  let revision = match load_task_set(data_dir).revision {
    Some(revision) => revision
    None => 0L
  }
  let mut session : RunSession? = None
  match control {
    None => ()
    Some(addr) => {
      let sc_addr = flags.get("state-remote")
      let link = peer_link(flags)
      let run_log = RunLog::open(applied.pipeline, fn(topic, records) {
        match sc_addr {
          // with a cluster, writes go through it (see append_to_cluster)
          Some(sc) => append_to_cluster(sc, topic, records, link)
          None => append_local(data_dir, topic, records)
        }
      })
      let detail : Map[String, Json] = {}
      detail["revision"] = Json::number(revision.to_double())
      detail["data_dir"] = Json::string(data_dir)
      detail["source"] = Json::string(source_kind_text(applied.spec.source))
      // the run-start record's OFFSET is the run's id: derived from the log,
      // never from a clock (two runs in the same millisecond stay distinct,
      // and the id can be recomputed from the record of the run).
      //
      // A run log that cannot be written means NO registration (rather than a
      // failed run): the data plane does not depend on being watched, and an id
      // invented without a log would be a number with nothing behind it. On a
      // cluster this is the ordinary case until the operator declares
      // `<task>.run-log` — a run-log topic is a topic, and declarations are
      // operator actions here (P3/P18), not something a runner does to a
      // cluster behind the operator's back.
      let started : Int64? = match run_log.event("run-start", detail) {
        Ok(base) => Some(base)
        Err(e) => {
          warn(
            "warning: cannot write the run log (\{e}); this run will not register. On a cluster, declare \{run_log_topic(applied.pipeline)} first.\n",
          )
          None
        }
      }
      match started {
        None => ()
        Some(base) => {
          let record = @client.RunRecord::{
            id: run_id_of(applied.pipeline, revision, base),
            task: applied.pipeline,
            revision,
            address: runner_host(),
            pid: runner_pid(),
            data_dir,
            progress: -1L,
            stopped: false,
            state: "",
          }
          let reporter = RunReporter::new(record, control, link)
          let run = RunSession::{ log: run_log, reporter, }
          run.reporter.report_now(-1L, false)
          warn(
            "run \{record.id} registered with \{addr}; the run log is \{run_log_topic(applied.pipeline)}\n",
          )
          session = Some(run)
        }
      }
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
    HttpSource(url, interval_ms, headers, ca) =>
      Some(@connectors.http_source(url, now, interval_ms, headers, ca))
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
    HttpSink(url, headers, ca) => @connectors.http_sink(url, headers, ca)
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
      topic_source_loop(
        applied, sink, chain, state, data_dir, from, resume, session,
      )
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
          // a source without offsets reports -1 as progress: the run table
          // says "no offsets" rather than inventing a position
          match session {
            Some(run) => run.batch(-1L, now_ms())
            None => ()
          }
        }
    }
  }
  // the graceful ending: the loop ran out of records (a one-shot source), so
  // the run says it stopped on purpose — a killed run never gets here, which
  // is how the platform tells the two apart (P37-2)
  match session {
    Some(run) => run.stop("exhausted", -1L)
    None => ()
  }
  cli_exit(0)
}

///|
/// The source kind, for the run log's `run-start` record (a run's record
/// should say what it was pulling from without anyone parsing the spec).
fn source_kind_text(source : @spec.SourceSpec) -> String {
  match source {
    TopicSource(_, _) => "topic"
    FileSource(_) => "file"
    HttpSource(_, _, _, _) => "http"
    StdinSource => "stdin"
    MqttSource(_) => "mqtt"
    KafkaSource(_) => "kafka"
  }
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
  match append_to_cluster(sc, topic, records, link) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Appends records to a topic of the CLUSTER: resolve the topic's leader
/// through the control plane, then produce there, returning the offset the
/// batch landed at.
///
/// Shared by the two writes a runner must not make into a node's data dir —
/// state (P36) and the run log (P37-2) — because a node's data dir has one
/// writer per partition, and a runner writing the same log the node
/// replicates leaves that node's cached end stale (measured in P36: five
/// entries on the leader, the follower reporting "caught up to 0").
fn append_to_cluster(
  sc : String,
  topic : String,
  records : Array[@protocol.Record],
  link : PeerLink,
) -> Result[Int64, String] {
  if topic.length() == 0 {
    return Err("a cluster append needs a topic name")
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
    Err(e) => return Err("leader lookup for \{topic}: \{e}")
  }
  let view = match @client.decode_partition_view(payload) {
    Ok(view) => view
    Err(e) => return Err("leader lookup for \{topic}: \{e}")
  }
  if view.leader.length() == 0 {
    return Err("\{topic}[0] has no leader yet; refusing to write nowhere")
  }
  let (host, port) = parse_listen_addr(view.leader)
  let producer = match
    connect_producer_transport(host, port, link.token, link.tls) {
    Ok(producer) => producer
    Err(e) => return Err("produce connect \{view.leader}: \{e}")
  }
  let sent = producer.send(topic, records)
  producer.close()
  match sent {
    Ok((base, _count)) => Ok(base)
    Err(e) => Err("produce to \{topic}: \{e}")
  }
}

///|
/// Appends records to a topic in this process's own data dir, returning the
/// offset the batch landed at. Safe when this process is the only writer of
/// that log (a standalone run); a cluster-attached run uses
/// `append_to_cluster` instead, for the reason written there.
fn append_local(
  data_dir : String,
  topic : String,
  records : Array[@protocol.Record],
) -> Result[Int64, String] {
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  match log.append(records) {
    Ok(base) => Ok(base)
    Err(e) => Err("append \{topic}: \{e}")
  }
}
