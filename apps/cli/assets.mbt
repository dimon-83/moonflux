// SPDX-License-Identifier: Apache-2.0
// The control plane's asset store (P11).
//
// What the *cluster* should be running: the applied pipeline, held once
// and pulled by every data node. The single-process shape (a broker
// applying to itself) is unchanged — this is the cluster口径, and the
// two are separate on purpose, because "deploy to this broker" and
// "deploy to the cluster" are different statements.
//
// Data nodes are caches, not authorities: each still validates what it
// runs (compile is pure, so every node derives the same topology), and
// a node whose local revision is *ahead* of the control plane keeps it
// — that is "the control plane has not caught up", not "go backwards".

///|
struct ClusterAsset {
  data_dir : String
  mut revision : Int64
  /// The cluster's TASK-SET document (P37). One document, one revision: a node
  /// adopts the whole set or none of it, because a half-adopted set would mean
  /// one node running yesterday's task list and another running today's.
  mut document : String
}

///|
/// How a publish changes the set. Three shapes, deliberately distinct:
/// upsert one task, make one task the whole set, or take a set document as the
/// whole set. The old single-pipeline `apply` was "replace"; it is now one of
/// three named actions instead of the silent default.
pub(all) enum PublishMode {
  Upsert
  Replace
  Set
}

///|
fn cluster_pipeline_path(data_dir : String) -> String {
  "\{data_dir}/pipeline.json"
}

///|
/// Builds the stored document from a task list: `{"schema":2,"pipelines":[...]}`.
/// The revision and applied_at live OUTSIDE it (the file carries them, the
/// reply carries the revision), so the document a node pulls is exactly the
/// shape `topology.json` uses.
fn cluster_document_of(tasks : Array[Json]) -> String {
  let root : Map[String, Json] = {}
  root["schema"] = Json::number(TASK_SET_SCHEMA.to_double())
  root["pipelines"] = Json::array(tasks)
  Json::object(root).stringify(indent=2)
}

///|
/// Reads the stored task objects out of a document, or an error naming what is
/// wrong with it. Reads the legacy single-spec file too (one task).
fn cluster_tasks_of(
  document : String,
  label : String,
) -> Result[Array[TaskDoc], String] {
  match parse_task_set_text(document, label) {
    Ok(set) => Ok(set.tasks)
    Err(e) => Err(e)
  }
}

///|
fn ClusterAsset::load(data_dir : String) -> ClusterAsset {
  let path = cluster_pipeline_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    _ => return ClusterAsset::{ data_dir, revision: 0L, document: "", }
  }
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => fail("read \{path}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => fail("corrupt \{path}: \{e}")
  }
  let revision = match json.value("revision") {
    Some(Number(n)) => n.to_int64()
    _ => 0L
  }
  // the stored file holds the revision and the timestamp next to the tasks;
  // the DOCUMENT is rebuilt from the tasks alone, so a node never receives the
  // control plane's bookkeeping fields as if they were part of its spec
  let document = match json.value("pipelines") {
    Some(Array(items)) => cluster_document_of(items)
    _ =>
      // the shape the previous version wrote: one spec at the top level
      match json.value("spec") {
        Some(spec) => {
          let name = match @spec.parse_spec(spec.stringify()) {
            Ok(parsed) => parsed.metadata_name
            Err(_) => ""
          }
          let applied_at = match json.value("applied_at") {
            Some(Number(n)) => n.to_int64()
            _ => 0L
          }
          cluster_document_of([task_json(name, spec, [], applied_at)])
        }
        None => ""
      }
  }
  ClusterAsset::{ data_dir, revision, document, }
}

///|
fn ClusterAsset::save(self : ClusterAsset) -> Result[Unit, String] {
  // parse the document back: saving must not be able to write something a node
  // could not read (the control plane is the authority, so its own file is the
  // first reader it has to satisfy)
  let tasks = match cluster_tasks_of(self.document, "the cluster's task set") {
    Ok(tasks) => tasks
    Err(e) => return Err(e)
  }
  let items : Array[Json] = []
  for task in tasks {
    items.push(task.json)
  }
  let root : Map[String, Json] = {}
  root["schema"] = Json::number(TASK_SET_SCHEMA.to_double())
  root["revision"] = Json::number(self.revision.to_double())
  root["applied_at"] = Json::number(
    @env.now().reinterpret_as_int64().to_double(),
  )
  root["pipelines"] = Json::array(items)
  let text = Json::object(root).stringify(indent=2)
  match @fs.mkdirs(self.data_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{self.data_dir}: \{e}")
  }
  let path = cluster_pipeline_path(self.data_dir)
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
/// Publishes to the cluster, in one of three shapes (P37). Validates first —
/// names unique, data topics unique, every transform compiles — then stores,
/// then bumps. A rejected document leaves the stored revision untouched, which
/// is the same publish-time discipline every apply path here follows and the
/// reason a broken task never reaches a node.
fn ClusterAsset::publish(
  self : ClusterAsset,
  text : String,
  mode : PublishMode,
  store : MetadataStore,
) -> Result[(Int64, Array[String]), String] {
  let existing = match cluster_tasks_of(self.document, "the stored task set") {
    Ok(tasks) => tasks
    Err(_) => [] // an empty or legacy document starts a fresh set
  }
  let tasks : Array[TaskDoc] = match mode {
    Set =>
      match task_docs_from_set_text(text, "the published set") {
        Ok(docs) => docs
        Err(e) => return Err(e)
      }
    Replace => {
      let spec = match parse_published_spec(text) {
        Ok(spec) => spec
        Err(e) => return Err(e)
      }
      [spec]
    }
    Upsert => {
      let task = match parse_published_spec(text) {
        Ok(task) => task
        Err(e) => return Err(e)
      }
      let merged : Array[TaskDoc] = []
      let mut replaced = false
      for old in existing {
        if old.name == task.name {
          merged.push(task)
          replaced = true
        } else {
          merged.push(old)
        }
      }
      if !replaced {
        merged.push(task)
      }
      merged
    }
  }
  match validate_tasks(tasks, self.data_dir) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  for task in tasks {
    for t in task.spec.transforms {
      match compile_node(store, self.data_dir, t) {
        Ok(_) => ()
        Err(e) => return Err("task \{task.name}: \{e}")
      }
    }
  }
  let items : Array[Json] = []
  let names : Array[String] = []
  for task in tasks {
    items.push(task.json)
    names.push(task.name)
  }
  self.revision = self.revision + 1L
  self.document = cluster_document_of(items)
  match self.save() {
    Ok(_) => Ok((self.revision, names))
    Err(e) => Err(e)
  }
}

///|
/// Removes one task from the cluster's set. An unknown name is refused and the
/// known ones are named: a delete that silently does nothing hides typos, and
/// on a control plane it also hides "you are deleting from the wrong cluster".
fn ClusterAsset::delete_task(
  self : ClusterAsset,
  name : String,
) -> Result[(Int64, Array[String]), String] {
  let tasks = match cluster_tasks_of(self.document, "the stored task set") {
    Ok(tasks) => tasks
    Err(e) => return Err(e)
  }
  let kept : Array[TaskDoc] = []
  let mut found = false
  for task in tasks {
    if task.name == name {
      found = true
    } else {
      kept.push(task)
    }
  }
  if !found {
    let known = if tasks.length() == 0 {
      "none"
    } else {
      task_names(TaskSet::{ tasks, revision: None, }).join(", ")
    }
    return Err("no task named \{name} on this cluster (tasks: \{known})")
  }
  let items : Array[Json] = []
  let names : Array[String] = []
  for task in kept {
    items.push(task.json)
    names.push(task.name)
  }
  self.revision = self.revision + 1L
  self.document = cluster_document_of(items)
  match self.save() {
    Ok(_) => Ok((self.revision, names))
    Err(e) => Err(e)
  }
}

///|
/// One published spec document, as a task.
fn parse_published_spec(text : String) -> Result[TaskDoc, String] {
  let spec = match @spec.parse_spec(text) {
    Ok(spec) => spec
    Err(errors) => {
      let sb = StringBuilder::new()
      for i, error in errors {
        if i > 0 {
          sb.write_string("; ")
        }
        sb.write_string("\{error.path}: \{error.message}")
      }
      return Err("invalid spec: \{sb.to_string()}")
    }
  }
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("invalid json: \{e}")
  }
  Ok(TaskDoc::{
    name: spec.metadata_name,
    spec,
    json: task_json(
      spec.metadata_name,
      json,
      [],
      @env.now().reinterpret_as_int64(),
    ),
  })
}

///|
/// The cluster revision this node is running, read back from its own
/// topology (a locally applied pipeline carries 0: "not cluster-managed",
/// which is also the revision a node starts from).
fn local_cluster_revision(data_dir : String) -> Int64 {
  let path = topology_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    _ => return 0L
  }
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(_) => return 0L
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch { _ => return 0L }
  match json.value("cluster_revision") {
    Some(Number(n)) => n.to_int64()
    _ => 0L
  }
}

///|
/// Pulls the pipeline document from the control plane.
fn fetch_cluster_pipeline(
  sc_addr : String,
  link : PeerLink,
) -> Result[@client.ClusterPipeline, String] {
  let payload = match
    control_call_secure(
      sc_addr,
      @client.CMD_CLUSTER_PIPELINE_FETCH,
      @utf8.encode("document please"),
      link,
    ) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_cluster_pipeline(payload)
}

///|
/// Pulls one function set from the control plane and stores it locally.
/// The node validates it through the same door a local `function-set
/// create` uses, so the control plane being the authority does not make
/// it the only guard.
fn pull_function_set(
  sc_addr : String,
  store : MetadataStore,
  name : String,
  link : PeerLink,
) -> Result[Unit, String] {
  let payload = match
    control_call_secure(
      sc_addr,
      @client.CMD_FUNCTION_SET_FETCH,
      @utf8.encode(name),
      link,
    ) {
    Ok(payload) => payload
    Err(e) => return Err("fetch function set \{name}: \{e}")
  }
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let (doc_name, functions) = match parse_function_set_asset(text) {
    Ok(parsed) => parsed
    Err(e) => return Err("function set \{name} from the control plane: \{e}")
  }
  let revision = function_set_doc_revision(text)
  match adopt_function_set(store, doc_name, functions, revision) {
    Ok(set) => {
      note(
        "pulled function set \{set.name} revision \{set.revision} from the control plane",
      )
      Ok(())
    }
    Err(e) => Err("store function set \{doc_name}: \{e}")
  }
}

///|
/// The revision a served asset document carries (0 when it does not say
/// one, which is what a hand-authored asset means).
fn function_set_doc_revision(text : String) -> Int64 {
  let json = @json.parse(text[0:text.length()]) catch { _ => return 0L }
  match json.value("revision") {
    Some(Number(n)) => n.to_int64()
    _ => 0L
  }
}

///|
/// Adopts the cluster's pipeline when the control plane is ahead of what
/// this node runs. Returns true when it did.
///
/// The order is the whole point: assets first (pull any function set the
/// spec references and this node lacks), then validate and compile
/// (publish-time checks, on this node, against the assets it just
/// reconciled), then persist — and only then does the hot-reload path
/// pick it up. A failure at any step leaves the running pipeline alone
/// and says so once.
struct AdoptionState {
  mut failed_revision : Int64
  mut reported : Bool
}

///|
/// Says why an adoption failed — **once per revision**. A node that
/// cannot adopt keeps running; a warning every 500ms forever is how a
/// log stops being read.
fn report_adoption_failure(
  state : AdoptionState,
  revision : Int64,
  reason : String,
) -> Unit {
  if state.reported && state.failed_revision == revision {
    return
  }
  state.failed_revision = revision
  state.reported = true
  note(
    "warning: cluster pipeline revision \{revision} not adopted: \{reason}; keeping the running pipeline",
  )
}

///|
fn adopt_cluster_pipeline(
  data_dir : String,
  sc_addr : String,
  store : MetadataStore,
  revision : Int64,
  state : AdoptionState,
  link : PeerLink,
) -> Bool {
  let local = local_cluster_revision(data_dir)
  if revision <= local {
    // never go backwards: a local revision ahead of the control plane
    // means the control plane has not caught up, not that this node
    // should run something older
    return false
  }
  let pipeline = match fetch_cluster_pipeline(sc_addr, link) {
    Ok(pipeline) => pipeline
    Err(e) => {
      report_adoption_failure(
        state,
        revision,
        "cannot fetch the cluster task set: \{e}",
      )
      return false
    }
  }
  if pipeline.document.length() == 0 {
    return false
  }
  // Parse the WHOLE set first: a document this node cannot read is not a
  // reason to start adopting half of it. (This is also the mixed-version
  // behaviour: an older node cannot read a set document as a spec, refuses it
  // here, and keeps running what it has — noisy, never silent.)
  let set = match
    parse_task_set_text(pipeline.document, "the cluster's task set") {
    Ok(set) => set
    Err(e) => {
      note(
        "warning: the cluster task set (revision \{revision}) is unreadable here (\{e}); keeping the running set",
      )
      return false
    }
  }
  // assets first: a task that references a set this node does not have is not
  // a reason to refuse the set, it is a reason to pull the set
  for task in set.tasks {
    for t in task.spec.transforms {
      let set_name = transform_function_set(t)
      if set_name == "" {
        continue
      }
      if get_function_set(store, set_name) is Ok(_) {
        continue
      }
      match pull_function_set(sc_addr, store, set_name, link) {
        Ok(_) => ()
        Err(e) => {
          report_adoption_failure(
            state,
            revision,
            "cannot pull function set \{set_name}: \{e}",
          )
          return false
        }
      }
    }
  }
  // then the publish-time check, here, against what this node will run
  for task in set.tasks {
    for t in task.spec.transforms {
      match compile_node(store, data_dir, t) {
        Ok(_) => ()
        Err(e) => {
          report_adoption_failure(
            state,
            revision,
            "task \{task.name} does not compile here: \{e}",
          )
          return false
        }
      }
    }
  }
  // ONE write for the whole set: a node never runs a half-adopted task list
  let items : Array[Json] = []
  let names : Array[String] = []
  for task in set.tasks {
    items.push(task.json)
    names.push(task.name)
  }
  match write_task_set(data_dir, items, Some(revision)) {
    Ok(_) => {
      note(
        "cluster task set revision \{revision} adopted (\{set.tasks.length()} task(s): \{names.join(", ")}); the next request reloads it",
      )
      true
    }
    Err(e) => {
      note("warning: cannot persist the cluster task set: \{e}")
      false
    }
  }
}

///|
/// The function set a transform references, or "" when it references none.
fn transform_function_set(t : @spec.TransformSpec) -> String {
  match t {
    @spec.ExprTransform(_expr, functions) => functions
    @spec.WasmTransform(_module_id, _config) => ""
    // a scalar transform references a name in the node's scalar registry, not
    // a function set (P26): nothing to collect here
    @spec.ScalarTransform(_function) => ""
    // a regex transform carries its pattern, not a function set
    @spec.RegexTransform(_pattern, _invert) => ""
    // a callout is host-side IO: it references no function set
    @spec.CalloutTransform(_callout) => ""
  }
}
