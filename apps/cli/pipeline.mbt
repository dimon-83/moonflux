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
  let doc_map : Map[String, Json] = {}
  doc_map["pipeline"] = Json::string(name)
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
  let applied = match load_applied(data_dir) {
    Some(applied) => applied
    None =>
      fail(
        "no applied pipeline under \{data_dir}; run: moonflux pipeline apply -f <spec>",
      )
  }
  if flags.get("name") is Some(want) {
    if want != applied.pipeline {
      fail("applied pipeline is '\{applied.pipeline}', not '\{want}'")
    }
  }
  let topology = @pipeline.compile(applied.spec)
  if !@pipeline.runnable(topology) {
    fail(
      "pipeline uses capabilities not available until P1 (mbel dynamic rules); P0 runtime refuses to execute",
    )
  }
  // 1. source: file -> records
  let records : Array[@protocol.Record] = match applied.spec.source {
    FileSource(path) =>
      match file_records(path) {
        Ok(records) => records
        Err(e) => fail(e)
      }
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
  // 3. sink: stdout, one line per record value
  let entries = match log.read(base, records.length()) {
    Ok(entries) => entries
    Err(e) => fail("read: \{e}")
  }
  for entry in entries {
    println(
      @utf8.decode_lossy(entry.record.value[0:entry.record.value.length()]),
    )
  }
  cli_exit(0)
}
