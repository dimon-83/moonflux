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
    Ok(spec) => Some(Applied::{ pipeline: name, spec })
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
/// Persists the compiled state: pipeline name + the spec document.
fn persist_applied(
  data_dir : String,
  name : String,
  spec_json : Json,
) -> Result[Unit, String] {
  // Clock lives in the apps layer (kernel red line: core never reads
  // the wall clock); the timestamp records when apply compiled+saved.
  let doc_map : Map[String, Json] = {}
  doc_map["pipeline"] = Json::string(name)
  doc_map["applied_at"] = Json::number(
    @env.now().reinterpret_as_int64().to_double(),
  )
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
      println("error: \{path}: \{errors.length()} spec error(s):")
      for e in errors {
        println("  \{e.path}: [\{e.code}] \{e.message}")
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
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let (spec, spec_json) = load_spec_doc(spec_path)
  let new_topology = @pipeline.compile(spec)
  // publish-time static check: every transform must compile before
  // the topology is persisted (AGENTS §8) — bad rules never apply
  for t in spec.transforms {
    let expr = match t {
      ExprTransform(expr) => expr
    }
    match @transform.compile(expr) {
      Ok(_) => ()
      Err(e) => fail("transform '\{expr}' rejected: \{e}")
    }
  }
  match persist_applied(data_dir, new_topology.pipeline, spec_json) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  println(
    "applied pipeline \{new_topology.pipeline}: \{new_topology.processes.length()} processes -> \{topology_path(data_dir)}",
  )
  cli_exit(0)
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
      Applied::{ pipeline: spec.metadata_name, spec }
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
  // dynamic rule chain: compiled once for this run (P1 capability)
  let chain : Array[@transform.Transform] = []
  for t in applied.spec.transforms {
    let expr = match t {
      ExprTransform(expr) => expr
    }
    match @transform.compile(expr) {
      Ok(compiled) => chain.push(compiled)
      Err(e) => fail("transform '\{expr}' rejected: \{e}")
    }
  }
  // 1. source: one pull through the connector framework
  let now = @env.now().reinterpret_as_int64()
  let source = match applied.spec.source {
    FileSource(path) => @connectors.file_source(path, now)
    HttpSource(url) => @connectors.http_source(url, now)
    StdinSource => @connectors.stdin_source(now)
  }
  let records = match (source.pull)() {
    Ok(records) => records
    Err(e) => fail("source \{source.name}: \{e}")
  }
  // 2. broker: append to the topic log
  let log = match open_topic_log(data_dir, applied.spec.topic.name) {
    Ok(log) => log
    Err(e) => fail(e)
  }
  let base = match log.append(records) {
    Ok(base) => base
    Err(e) => fail("append: \{e}")
  }
  // 3. dynamic rules on the consumption path, then the sink
  let entries = match log.read(base, records.length()) {
    Ok(entries) => entries
    Err(e) => fail("read: \{e}")
  }
  let out_records : Array[@protocol.Record] = []
  for entry in entries {
    match @transform.apply_chain(chain, entry.record) {
      Ok(record) => out_records.push(record)
      Err(e) => fail("transform: \{e}")
    }
  }
  let sink = match applied.spec.sink {
    StdoutSink => @connectors.stdout_sink()
    HttpSink(url) => @connectors.http_sink(url)
  }
  match (sink.flush)(out_records) {
    Ok(_) => ()
    Err(e) => fail("sink \{sink.name}: \{e}")
  }
  cli_exit(0)
}
