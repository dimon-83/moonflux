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
  mut spec_json : String
}

///|
fn cluster_pipeline_path(data_dir : String) -> String {
  "\{data_dir}/pipeline.json"
}

///|
fn ClusterAsset::load(data_dir : String) -> ClusterAsset {
  let path = cluster_pipeline_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    _ => return ClusterAsset::{ data_dir, revision: 0L, spec_json: "" }
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
  let spec_json = match json.value("spec") {
    Some(spec) => spec.stringify()
    None => ""
  }
  ClusterAsset::{ data_dir, revision, spec_json }
}

///|
fn ClusterAsset::save(self : ClusterAsset) -> Result[Unit, String] {
  let root : Map[String, Json] = {}
  root["revision"] = Json::number(self.revision.to_double())
  root["applied_at"] = Json::number(
    @env.now().reinterpret_as_int64().to_double(),
  )
  let spec = @json.parse(self.spec_json[0:self.spec_json.length()]) catch {
    e => return Err("stored spec is not valid JSON: \{e}")
  }
  root["spec"] = spec
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
/// Publishes a pipeline to the cluster: validate, then store, then bump.
/// A rejected document leaves the stored revision untouched — the same
/// publish-time discipline every apply path here follows, and the
/// reason a broken spec never reaches a node.
fn ClusterAsset::publish(
  self : ClusterAsset,
  spec_text : String,
  store : MetadataStore,
) -> Result[Int64, String] {
  let spec = match @spec.parse_spec(spec_text) {
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
  // the same publish-time check the node applies, run where the
  // authority is: a pipeline that cannot compile anywhere must not
  // become the cluster's desired state
  for t in spec.transforms {
    match compile_node(store, t) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  self.revision = self.revision + 1L
  self.spec_json = spec_text
  match self.save() {
    Ok(_) => Ok(self.revision)
    Err(e) => Err(e)
  }
}

// ---------------------------------------------------------------------
// The node side: a data node is a *cache* of the cluster's assets. It
// pulls the pipeline when the revision moves, pulls the function sets a
// pipeline references when they are missing or behind, and runs what it
// validated itself — compile is pure, so every node derives the same
// topology from the same document.

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
  token : String?,
) -> Result[@client.ClusterPipeline, String] {
  let payload = match
    control_call_with_token(
      sc_addr,
      @client.CMD_CLUSTER_PIPELINE_FETCH,
      @utf8.encode("document please"),
      token,
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
  token : String?,
) -> Result[Unit, String] {
  let payload = match
    control_call_with_token(
      sc_addr,
      @client.CMD_FUNCTION_SET_FETCH,
      @utf8.encode(name),
      token,
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
  token : String?,
) -> Bool {
  let local = local_cluster_revision(data_dir)
  if revision <= local {
    // never go backwards: a local revision ahead of the control plane
    // means the control plane has not caught up, not that this node
    // should run something older
    return false
  }
  let pipeline = match fetch_cluster_pipeline(sc_addr, token) {
    Ok(pipeline) => pipeline
    Err(e) => {
      report_adoption_failure(
        state,
        revision,
        "cannot fetch the cluster pipeline: \{e}",
      )
      return false
    }
  }
  if pipeline.spec_json.length() == 0 {
    return false
  }
  let spec = match @spec.parse_spec(pipeline.spec_json) {
    Ok(spec) => spec
    Err(errors) => {
      note(
        "warning: the cluster pipeline (revision \{revision}) is invalid on this node (\{errors.length()} error(s)); keeping the running pipeline",
      )
      return false
    }
  }
  // assets first: a spec that references a set this node does not have
  // is not a reason to refuse the pipeline, it is a reason to pull it
  for t in spec.transforms {
    let set_name = match t {
      @spec.ExprTransform(_expr, functions) => functions
      @spec.WasmTransform(_module_id, _config) => ""
    }
    if set_name == "" {
      continue
    }
    if get_function_set(store, set_name) is Ok(_) {
      continue
    }
    match pull_function_set(sc_addr, store, set_name, token) {
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
  // then the publish-time check, here, against what this node will run
  for t in spec.transforms {
    match compile_node(store, t) {
      Ok(_) => ()
      Err(e) => {
        report_adoption_failure(
          state,
          revision,
          "the pipeline does not compile here: \{e}",
        )
        return false
      }
    }
  }
  let json = @json.parse(pipeline.spec_json[0:pipeline.spec_json.length()]) catch {
    _ => return false
  }
  match
    persist_applied(data_dir, spec.metadata_name, json, [], Some(revision)) {
    Ok(_) => {
      note(
        "cluster pipeline revision \{revision} adopted (\{spec.metadata_name}); the next request reloads it",
      )
      true
    }
    Err(e) => {
      note("warning: cannot persist the cluster pipeline: \{e}")
      false
    }
  }
}
