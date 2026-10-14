// SPDX-License-Identifier: Apache-2.0
// The task SET: what used to be "the applied pipeline" is now a collection.
//
// P37 (README decision 79): one node used to hold exactly one applied
// pipeline ({pipeline, spec} in topology.json), which is why "manage tasks"
// could not exist. The document is a set now, with ONE document-level
// revision — a node adopts the whole set or none of it (P11's discipline,
// unchanged: a half-adopted set would mean one node running yesterday's task
// list and another running today's).
//
// Two shapes are read, one is written:
//
//   v2  { "schema": 2, "cluster_revision": N?,
//         "pipelines": [ {pipeline, applied_at, functions[], spec}, ... ] }
//   v1  { "pipeline": name, "applied_at": ..., "functions": [...], "spec": {...},
//         "cluster_revision": N? }                       <- migrated in memory
//
// A v1 document is a one-task set. Migration happens on READ and is never
// written back implicitly: a node that has not been asked to change anything
// should not rewrite its own state file (and a mixed-version cluster keeps
// working: an old reader sees a set document it cannot parse as a spec,
// refuses it, and keeps running what it has — noisy, never silent).
//
// The per-task JSON object is preserved VERBATIM across rewrites: upserting
// task A must not restamp task B's applied_at or drop a field this version
// does not know about.

///|
/// One task as stored: its name, its parsed spec (the thing callers need),
/// and the stored JSON object it came from (so a rewrite can preserve the
/// siblings byte-for-byte in meaning).
struct TaskDoc {
  name : String
  spec : @spec.PipelineSpec
  json : Json
  /// Restart policy for this task (never|on-failure|always). Lives in the task
  /// set document — the deployment concern — not in the PipelineSpec, which is
  /// the dataflow. The runner reads it; `--restart` overrides it per run.
  restart : String
}

///|
/// The task set, sorted by name for determinism (a list that reorders itself
/// between runs is a list nobody can diff).
struct TaskSet {
  tasks : Array[TaskDoc]
  /// The control plane's revision this set was adopted from, if any.
  revision : Int64?
}

///|
const TASK_SET_SCHEMA : Int32 = 2

///|
/// The restart policy a stored task document declares, or the default. Reading
/// is lenient here because the set-document path (task_docs_from_pipelines)
/// validates before storing; the runner validates again at spawn time.
fn restart_of(json : Json) -> String {
  match json.value("restart") {
    Some(String(s)) => s
    _ => "on-failure"
  }
}

///|
/// Parses a task-set document. Shared by the file loader and by
/// `pipeline list --remote` (the control plane serves the same document), so
/// both read a set the same way.
fn parse_task_set_text(
  text : String,
  label : String,
) -> Result[TaskSet, String] {
  let doc = @json.parse(text[0:text.length()]) catch {
    e => return Err("corrupt \{label}: \{e}")
  }
  let revision = match doc.value("cluster_revision") {
    Some(Number(n)) => Some(n.to_int64())
    _ => None
  }
  // v2 when the document names its pipelines; v1 otherwise (one task)
  let items : Array[Json] = match doc.value("pipelines") {
    Some(Array(items)) => items
    _ =>
      match doc.value("spec") {
        Some(_) => [doc]
        None =>
          return Err("corrupt \{label}: neither \"pipelines\" nor \"spec\"")
      }
  }
  let tasks : Array[TaskDoc] = []
  for item in items {
    let name = match item.value("pipeline") {
      Some(String(name)) => name
      _ => return Err("corrupt \{label}: a task without a pipeline name")
    }
    let spec_json = match item.value("spec") {
      Some(spec_json) => spec_json
      _ => return Err("corrupt \{label}: task \{name} has no spec")
    }
    let spec_text = spec_json.stringify()
    let spec = match @spec.parse_spec(spec_text) {
      Ok(spec) => spec
      Err(errors) => {
        let sb = StringBuilder::new()
        sb.write_string(
          "corrupt \{label}: stored spec for \{name} no longer valid: ",
        )
        for e in errors {
          sb.write_string("\{e.code} at \{e.path}; ")
        }
        return Err(sb.to_string())
      }
    }
    tasks.push(TaskDoc::{ name, spec, json: item, restart: restart_of(item), })
  }
  Ok(TaskSet::{ tasks: sort_tasks(tasks), revision, })
}

///|
/// Reads the task set from a data dir. Missing file = an empty set (never
/// applied).
fn try_load_task_set(data_dir : String) -> Result[TaskSet, String] {
  let path = topology_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    Ok(false) => return Ok(TaskSet::{ tasks: [], revision: None, })
    Err(e) => return Err("stat \{path}: \{e}")
  }
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => return Err("read \{path}: \{e}")
  }
  parse_task_set_text(@utf8.decode_lossy(bytes[0:bytes.length()]), path)
}

///|
/// The task set, or a fatal error. Host code fails loudly on corrupt state
/// (a broker that cannot read its own task list must not pretend it has
/// none).
fn load_task_set(data_dir : String) -> TaskSet {
  match try_load_task_set(data_dir) {
    Ok(set) => set
    Err(e) => fail(e)
  }
}

///|
/// Name order, so every reader of this list sees the same order.
fn sort_tasks(tasks : Array[TaskDoc]) -> Array[TaskDoc] {
  let sorted = tasks.copy()
  // insertion sort: task sets are small (one entry per pipeline a cluster
  // runs), and this keeps the ordering rule visible
  for i = 1; i < sorted.length(); i = i + 1 {
    let mut j = i
    while j > 0 && sorted[j - 1].name > sorted[j].name {
      let tmp = sorted[j - 1]
      sorted[j - 1] = sorted[j]
      sorted[j] = tmp
      j = j - 1
    }
  }
  sorted
}

///|
/// The tasks' names, in order.
fn task_names(set : TaskSet) -> Array[String] {
  let out : Array[String] = []
  for task in set.tasks {
    out.push(task.name)
  }
  out
}

///|
/// Finds a task by name.
fn TaskSet::find(self : TaskSet, name : String) -> TaskDoc? {
  for task in self.tasks {
    if task.name == name {
      return Some(task)
    }
  }
  None
}

///|
/// The per-task JSON object as it is stored. Callers pass what apply knows
/// (the raw spec document, the function-set revisions it resolved, when it
/// applied); the shape is in one place so v1/v2 cannot drift.
fn task_json(
  name : String,
  spec_json : Json,
  function_sets : Array[(String, Int64)],
  applied_at : Int64,
  restart : String,
) -> Json {
  let doc : Map[String, Json] = {}
  doc["pipeline"] = Json::string(name)
  doc["applied_at"] = Json::number(applied_at.to_double())
  doc["restart"] = Json::string(restart)
  let set_items : Array[Json] = []
  for pair in function_sets {
    let (set_name, revision) = pair
    let item : Map[String, Json] = {}
    item["name"] = Json::string(set_name)
    item["revision"] = Json::number(revision.to_double())
    set_items.push(Json::object(item))
  }
  doc["functions"] = Json::array(set_items)
  doc["spec"] = spec_json
  Json::object(doc)
}

///|
/// Writes the task set, atomically and always as v2. The caller owns
/// validation (see `validate_tasks`): this function is about the file, not
/// about whether the set makes sense.
fn write_task_set(
  data_dir : String,
  tasks : Array[Json],
  revision : Int64?,
) -> Result[Unit, String] {
  let root : Map[String, Json] = {}
  root["schema"] = Json::number(TASK_SET_SCHEMA.to_double())
  match revision {
    Some(revision) =>
      root["cluster_revision"] = Json::number(revision.to_double())
    None => ()
  }
  root["pipelines"] = Json::array(tasks)
  let text = Json::object(root).stringify(indent=2)
  match @fs.mkdirs(data_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{data_dir}: \{e}")
  }
  let path = topology_path(data_dir)
  let tmp = "\{path}.tmp"
  match @fs.write_file(tmp, @utf8.encode(text[0:text.length()])) {
    Ok(_) => ()
    Err(e) => return Err("write \{tmp}: \{e}")
  }
  match @fs.rename(tmp, path) {
    Ok(_) => Ok(())
    Err(e) => Err("rename \{tmp} -> \{path}: \{e}")
  }
}

///|
/// The two rules a task set must satisfy before it is stored:
///
///  1. names are unique (a name is how a task is addressed: apply, delete,
///     run --name);
///  2. **data topics are unique** — the read path picks the transform chain
///     BY TOPIC (`RuleState::chain_for_topic`), so two tasks claiming one
///     topic is not a preference, it is an ambiguity. Refused by name,
///     naming both tasks.
///
/// Transform compilation stays a publish-time check (AGENTS §8) and is done
/// by the caller, which has the metadata store.
fn validate_tasks(
  tasks : Array[TaskDoc],
  data_dir : String,
) -> Result[Unit, String] {
  let seen : Map[String, String] = {}
  for task in tasks {
    match seen.get(task.name) {
      Some(_) =>
        return Err("two tasks are named \{task.name}; a name must be unique")
      None => seen[task.name] = task.name
    }
  }
  // topic -> task that claimed it
  let topics : Map[String, String] = {}
  for task in tasks {
    let topic = task.spec.topic.name
    if topic.length() == 0 {
      // the degenerate self-hosting case (P7): a pipeline with no
      // declaration at all. Two of them would both want (topic 0 of "")
      // — refuse rather than guess.
      match topics.get("") {
        Some(other) =>
          return Err(
            "tasks \{other} and \{task.name} both declare no topic; the read path could not tell them apart",
          )
        None => topics[""] = task.name
      }
      continue
    }
    match topics.get(topic) {
      Some(other) =>
        return Err(
          "tasks \{other} and \{task.name} both declare topic \{topic}; the read path picks the chain by topic, so a topic belongs to exactly one task",
        )
      None => topics[topic] = task.name
    }
  }
  let _ = data_dir
  Ok(())
}

///|
/// The task set as it should be listed: one line per task, tab separated
/// (the shape `topic list` uses, so `cut -f1` works in a gate).
fn task_list_lines(set : TaskSet) -> Array[String] {
  let out : Array[String] = []
  for task in set.tasks {
    let applied_at = match task.json.value("applied_at") {
      Some(Number(n)) => n.to_int64().to_string()
      _ => "-"
    }
    let functions = match task.json.value("functions") {
      Some(Array(items)) => {
        let parts : Array[String] = []
        for item in items {
          let name = match item.value("name") {
            Some(String(name)) => name
            _ => "?"
          }
          let revision = match item.value("revision") {
            Some(Number(n)) => n.to_int64().to_string()
            _ => "?"
          }
          parts.push("\{name}@\{revision}")
        }
        if parts.length() == 0 {
          "-"
        } else {
          parts.join(",")
        }
      }
      _ => "-"
    }
    out.push(
      "\{task.name}\ttopic=\{task.spec.topic.name}\ttransforms=\{task.spec.transforms.length()}\tfunctions=\{functions}\tapplied_at=\{applied_at}",
    )
  }
  out
}

///|
/// How many tasks a data dir holds right now. Used by the compat readers
/// (`applied_topic`, the health check) that only need to know whether the
/// node is cluster-managed or locally applied at all.
fn task_count(data_dir : String) -> Int32 {
  match try_load_task_set(data_dir) {
    Ok(set) => set.tasks.length()
    Err(_) => 0
  }
}

///|
/// Parses a SET document's `pipelines` array into task documents. Each element
/// is either a stored task object (`{pipeline, spec, ...}`) or a bare spec
/// document; both are accepted because that is what makes a catalog
/// round-trip, and because the control plane and the CLI must not disagree
/// about what a set document is.
///
/// `write_task_set` is the inverse for the CLI's `--set`; the control plane
/// uses this to accept one.
fn task_docs_from_pipelines(
  items : Array[Json],
) -> Result[Array[TaskDoc], String] {
  let out : Array[TaskDoc] = []
  for item in items {
    // Two shapes, and the difference is exactly where the document lives:
    //   a stored task object: {pipeline, spec: <whole document>, ...}
    //   a bare spec document: {apiVersion, kind, metadata, spec: <body>}
    // Reading `item["spec"]` for both would hand the parser the BODY of a bare
    // spec (its source/topic/transforms live one level up), which the parser
    // refuses — measured, and the reason this comment exists.
    let (name, spec_json) = match item.value("pipeline") {
      Some(String(name)) =>
        match item.value("spec") {
          Some(spec_json) => (name, spec_json)
          None => return Err("task \{name} has no spec")
        }
      _ =>
        match @spec.parse_spec(item.stringify()) {
          Ok(spec) => (spec.metadata_name, item)
          Err(errors) => {
            let sb = StringBuilder::new()
            sb.write_string("a spec in the set did not parse (")
            sb.write_string(errors.length().to_string())
            sb.write_string(" error(s)): ")
            for e in errors {
              sb.write_string("\{e.path}: \{e.message}; ")
            }
            return Err(sb.to_string())
          }
        }
    }
    let spec = match @spec.parse_spec(spec_json.stringify()) {
      Ok(spec) => spec
      Err(errors) => {
        let sb = StringBuilder::new()
        sb.write_string("the spec for task \{name} did not parse: ")
        for e in errors {
          sb.write_string("\{e.path}: \{e.message}; ")
        }
        return Err(sb.to_string())
      }
    }
    // Always store the canonical task object: a bare spec element becomes
    // {pipeline, applied_at, functions, spec}. Leaving it bare would make the
    // stored document depend on how it arrived, and a later reader that wants
    // applied_at/functions would find neither.
    let restart = restart_of(item)
    out.push(TaskDoc::{
      name,
      spec,
      json: task_json(
        name,
        spec_json,
        [],
        @env.now().reinterpret_as_int64(),
        restart,
      ),
      restart,
    })
  }
  Ok(out)
}

///|
/// Parses a document that is meant to be a SET: `{"pipelines": [...]}`. Used
/// by `apply --set` and by the control plane's set verb.
fn task_docs_from_set_text(
  text : String,
  label : String,
) -> Result[Array[TaskDoc], String] {
  let doc = @json.parse(text[0:text.length()]) catch {
    e => return Err("\{label}: invalid json: \{e}")
  }
  match doc.value("pipelines") {
    Some(Array(items)) => task_docs_from_pipelines(items)
    _ => Err("\{label}: expected a set document (\"pipelines\": [...])")
  }
}
