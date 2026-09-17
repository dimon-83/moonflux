// SPDX-License-Identifier: Apache-2.0
// The control plane's metadata store (P3).
//
// Two things live here, and keeping them apart is the point:
//
//   * the *declared* topics — the desired state an operator authors
//     (which topics exist, how many partitions, how many replicas);
//   * the *derived* placement — which nodes hold which partition and
//     who leads it, which is `core/cluster`'s reconcile output.
//
// The store is deliberately pluggable through an injected interface
// (the same shape as SegmentFile and OperatorEngine): today the only
// backend is a local file, and the K8s CRD backend that AGENTS §1.2
// anticipates becomes a second implementation rather than a rewrite.
// Being honest about that: one backend exists, and it says so.

///|
/// The metadata as it exists on disk, and the version it was written
/// at. The version is what makes a second writer detectable: this
/// project runs a single control plane (stated, not implied), and a
/// conflicting write is refused rather than silently merged.
pub(all) struct ClusterMetadata {
  topics : Array[ClusterMetadataTopic]
  /// Rule assets (P6). Same document, same version counter: one
  /// control-plane state, one conflict story.
  function_sets : Array[ClusterMetadataFunctionSet]
  /// monotonic; bumped on every successful save
  version : Int64
} derive(Debug, Eq, Show)

///|
/// A declared topic, as authored.
pub(all) struct ClusterMetadataTopic {
  name : String
  partitions : Int
  replication_factor : Int
} derive(Debug, Eq, Show)

///|
/// One function of a set: an expression body with explicit parameters
/// (the asset form of `@transform.RuleFunction`, plus the description
/// mbel's JSON v1 carries for humans).
pub(all) struct ClusterMetadataFunction {
  name : String
  params : Array[String]
  body : String
  description : String?
} derive(Debug, Eq, Show)

///|
/// A function set as authored: a named, versioned rule asset. The
/// revision is per-asset and monotonic — it is what a spec's apply
/// records, so an operator can tell which revision a running pipeline
/// was compiled against.
pub(all) struct ClusterMetadataFunctionSet {
  name : String
  revision : Int64
  functions : Array[ClusterMetadataFunction]
} derive(Debug, Eq, Show)

///|
/// Storage failures, all structured: the control plane's own bugs and
/// an operator's bad input must be tellable apart.
pub(all) suberror MetadataError {
  /// The document could not be parsed or has the wrong shape.
  Corrupt(String)
  /// The requested change is not allowed (duplicate name, bad range).
  Rejected(String)
  /// Another writer moved the version underneath this one.
  Conflict(String)
  /// The backend failed.
  Storage(String)
}

///|
pub impl Show for MetadataError with fn output(self, logger) {
  match self {
    Corrupt(msg) => logger.write_string("Corrupt(\{msg})")
    Rejected(msg) => logger.write_string("Rejected(\{msg})")
    Conflict(msg) => logger.write_string("Conflict(\{msg})")
    Storage(msg) => logger.write_string("Storage(\{msg})")
  }
}

///|
/// Where metadata comes from and goes to. Injected, so a control plane
/// can be tested against memory and later pointed at a CRD.
pub(all) struct MetadataStore {
  /// Reads the current document. `version` is carried through so a
  /// writer can detect that someone else moved it.
  load : () -> Result[ClusterMetadata, MetadataError]
  /// Writes the document. The backend is responsible for atomicity
  /// (the local one renames a temp file over the target).
  save : (ClusterMetadata) -> Result[Unit, MetadataError]
} derive(Debug)

///|
/// The local backend: one JSON document beside the placement state.
/// Atomic via temp-file + rename, because a control plane that can
/// lose half a metadata write is worse than one that cannot write.
pub fn file_metadata_store(data_dir : String) -> MetadataStore {
  let path = "\{data_dir}/metadata.json"
  MetadataStore::{
    load: fn() {
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(_) =>
          return Ok(ClusterMetadata::{
            topics: [],
            function_sets: [],
            version: 0L,
          })
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      let json = @json.parse(text[0:text.length()]) catch {
        e => return Err(Corrupt("\{path} is not valid JSON: \{e}"))
      }
      let obj = match json {
        Object(obj) => obj
        _ => return Err(Corrupt("\{path} must be a JSON object"))
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
        Some(_) => return Err(Corrupt("\{path}: topics must be an array"))
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
        Some(_) =>
          return Err(Corrupt("\{path}: function_sets must be an array"))
        None => ()
      }
      Ok(ClusterMetadata::{ topics, function_sets, version })
    },
    save: fn(metadata) {
      let items : Array[Json] = []
      for topic in metadata.topics {
        let doc_map : Map[String, Json] = {}
        doc_map["name"] = Json::string(topic.name)
        doc_map["partitions"] = Json::number(topic.partitions.to_double())
        doc_map["replication_factor"] = Json::number(
          topic.replication_factor.to_double(),
        )
        items.push(Json::object(doc_map))
      }
      let set_items : Array[Json] = []
      for set in metadata.function_sets {
        set_items.push(encode_function_set_doc(set))
      }
      let root_map : Map[String, Json] = {}
      root_map["version"] = Json::number(metadata.version.to_double())
      root_map["topics"] = Json::array(items)
      root_map["function_sets"] = Json::array(set_items)
      let text = Json::object(root_map).stringify(indent=2)
      match @fs.mkdirs(data_dir) {
        Ok(_) => ()
        Err(e) => return Err(Storage("mkdir \{data_dir}: \{e}"))
      }
      // write-then-rename: a reader never sees a half-written document
      let tmp = "\{path}.tmp"
      match @fs.write_file(tmp, @utf8.encode(text[0:text.length()])) {
        Ok(_) => ()
        Err(e) => return Err(Storage("write \{tmp}: \{e}"))
      }
      match @fs.rename(tmp, path) {
        Ok(_) => Ok(())
        Err(e) => Err(Storage("rename \{tmp} -> \{path}: \{e}"))
      }
    },
  }
}

///|
/// An in-memory store, for tests and for a control plane started
/// without a data dir.
pub fn memory_metadata_store() -> MetadataStore {
  let cell : Array[ClusterMetadata] = [
    ClusterMetadata::{ topics: [], function_sets: [], version: 0L },
  ]
  MetadataStore::{
    load: fn() { Ok(cell[0]) },
    save: fn(metadata) {
      cell[0] = metadata
      Ok(())
    },
  }
}

///|
fn decode_topic_doc(json : Json) -> Result[ClusterMetadataTopic, MetadataError] {
  let obj = match json {
    Object(obj) => obj
    _ => return Err(Corrupt("topic declaration must be an object"))
  }
  let name = match obj.get("name") {
    Some(String(name)) => name
    _ => return Err(Corrupt("topic declaration needs a name"))
  }
  let partitions = match obj.get("partitions") {
    Some(Number(n)) => n.to_int()
    _ => 1
  }
  let rf = match obj.get("replication_factor") {
    Some(Number(n)) => n.to_int()
    _ => 1
  }
  Ok(ClusterMetadataTopic::{ name, partitions, replication_factor: rf })
}

///|
/// Validates a topic declaration before it becomes metadata. The name
/// whitelist is core/spec's (one rule, one place); the numbers are
/// bounded here because a partition count is a plan, not a wish.
pub fn validate_topic_decl(
  decl : ClusterMetadataTopic,
) -> Result[Unit, MetadataError] {
  if !@spec.valid_topic_name(decl.name) {
    return Err(
      Rejected("invalid topic name '\{decl.name}' (1..128 of [a-z0-9._-])"),
    )
  }
  if decl.partitions <= 0 || decl.partitions > 1024 {
    return Err(Rejected("partitions must be 1..1024"))
  }
  if decl.replication_factor <= 0 || decl.replication_factor > 16 {
    return Err(Rejected("replication_factor must be 1..16"))
  }
  Ok(())
}

///|
/// Adds a topic to the metadata and persists it.
///
/// The version check is the whole concurrency story: load, compare,
/// write, and refuse if the document moved underneath. With one
/// control plane this never fires; the point is that a second one
/// fails loudly instead of last-writer-wins.
pub fn create_topic(
  store : MetadataStore,
  decl : ClusterMetadataTopic,
) -> Result[ClusterMetadata, MetadataError] {
  match validate_topic_decl(decl) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let current = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  for topic in current.topics {
    if topic.name == decl.name {
      return Err(Rejected("topic \{decl.name} already exists"))
    }
  }
  let topics : Array[ClusterMetadataTopic] = []
  for topic in current.topics {
    topics.push(topic)
  }
  topics.push(decl)
  let next = ClusterMetadata::{
    topics,
    function_sets: current.function_sets,
    version: current.version + 1L,
  }
  match (store.save)(next) {
    Ok(_) => Ok(next)
    Err(e) => Err(e)
  }
}

///|
/// Removes a topic. Removing them from the declarations is what makes
/// the control plane reconcile the partitions away (level-triggered:
/// the absence is the instruction, there is no delete event).
pub fn delete_topic(
  store : MetadataStore,
  name : String,
) -> Result[ClusterMetadata, MetadataError] {
  let current = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let kept : Array[ClusterMetadataTopic] = []
  let mut found = false
  for topic in current.topics {
    if topic.name == name {
      found = true
    } else {
      kept.push(topic)
    }
  }
  if !found {
    return Err(Rejected("no such topic \{name}"))
  }
  let next = ClusterMetadata::{
    topics: kept,
    function_sets: current.function_sets,
    version: current.version + 1L,
  }
  match (store.save)(next) {
    Ok(_) => Ok(next)
    Err(e) => Err(e)
  }
}

///|
/// Lists the declared topics, name-sorted so two reads agree.
pub fn list_topics(
  store : MetadataStore,
) -> Result[Array[ClusterMetadataTopic], MetadataError] {
  let metadata = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let topics : Array[ClusterMetadataTopic] = []
  for topic in metadata.topics {
    topics.push(topic)
  }
  topics.sort_by(fn(a, b) { a.name.compare(b.name) })
  Ok(topics)
}

// ---------------------------------------------------------------------
// Function sets (P6): rule assets for expression transforms.
//
// A function set is governance-isomorphic to an operator (README 决策
// 30): an artifact, a monotonic revision, publish-time validation, a
// budget, fail-closed execution. What differs is where it runs — host-
// side mbel instead of the wasmtime sandbox — which is a consequence
// of the trust boundary, not a shortcut: these assets are reviewed and
// deployed by the platform, so they are trusted code by definition.
// Untrusted scalar functions are the ABI v2 design's problem
// (docs/operator-abi-v2-scalar.md).

///|
/// The asset limits, stated because they bound the metadata document a
/// control plane must load, validate and ship on every apply.
const MAX_FUNCTIONS_PER_SET = 1024

///|
const MAX_FUNCTION_BODY_CHARS = 8192

///|
const MAX_FUNCTION_PARAMS = 32

///|
fn decode_function_doc(
  json : Json,
) -> Result[ClusterMetadataFunction, MetadataError] {
  let obj = match json {
    Object(obj) => obj
    _ => return Err(Corrupt("function must be an object"))
  }
  for key, _ in obj {
    if key != "name" && key != "params" && key != "body" && key != "description" {
      return Err(
        Rejected(
          "function field '\{key}' is not allowed (name, params, body, description)",
        ),
      )
    }
  }
  let name = match obj.get("name") {
    Some(String(name)) => name
    _ => return Err(Corrupt("function needs a string name"))
  }
  let body = match obj.get("body") {
    Some(String(body)) => body
    _ => return Err(Corrupt("function \{name} needs a string body"))
  }
  let params : Array[String] = match obj.get("params") {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(p) => out.push(p)
          _ => return Err(Corrupt("function \{name}: params must be strings"))
        }
      }
      out
    }
    Some(_) => return Err(Corrupt("function \{name}: params must be an array"))
    None => []
  }
  let description = match obj.get("description") {
    Some(String(text)) => Some(text)
    Some(_) =>
      return Err(Corrupt("function \{name}: description must be a string"))
    None => None
  }
  Ok(ClusterMetadataFunction::{ name, params, body, description })
}

///|
fn decode_function_set_doc(
  json : Json,
) -> Result[ClusterMetadataFunctionSet, MetadataError] {
  let obj = match json {
    Object(obj) => obj
    _ => return Err(Corrupt("function set must be an object"))
  }
  let name = match obj.get("name") {
    Some(String(name)) => name
    _ => return Err(Corrupt("function set needs a string name"))
  }
  let revision = match obj.get("revision") {
    Some(Number(n)) => n.to_int64()
    _ => 0L
  }
  let functions : Array[ClusterMetadataFunction] = match obj.get("functions") {
    Some(Array(items)) => {
      let out : Array[ClusterMetadataFunction] = []
      for item in items {
        match decode_function_doc(item) {
          Ok(f) => out.push(f)
          Err(e) => return Err(e)
        }
      }
      out
    }
    Some(_) =>
      return Err(Corrupt("function set \{name}: functions must be an array"))
    None => return Err(Corrupt("function set \{name} needs a functions array"))
  }
  Ok(ClusterMetadataFunctionSet::{ name, revision, functions })
}

///|
fn encode_function_set_doc(set : ClusterMetadataFunctionSet) -> Json {
  let fn_items : Array[Json] = []
  for f in set.functions {
    let fn_map : Map[String, Json] = {}
    fn_map["name"] = Json::string(f.name)
    fn_map["params"] = Json::array(f.params.map(fn(p) { Json::string(p) }))
    fn_map["body"] = Json::string(f.body)
    match f.description {
      Some(text) => fn_map["description"] = Json::string(text)
      None => ()
    }
    fn_items.push(Json::object(fn_map))
  }
  let set_map : Map[String, Json] = {}
  set_map["name"] = Json::string(set.name)
  set_map["revision"] = Json::number(set.revision.to_double())
  set_map["functions"] = Json::array(fn_items)
  Json::object(set_map)
}

///|
/// Parses the asset document an operator authors:
///   { "name": "pricing", "functions": [ { "name": "tax",
///     "params": ["price", "rate"], "body": "price * rate" } ] }
/// Field names for the function entries are mbel's JSON v1, so a
/// playground function document transfers with only its envelope
/// adjusted. Unknown fields are refused: an asset that says something
/// the platform ignores is an asset that lies to its reviewer.
pub fn parse_function_set_asset(
  text : String,
) -> Result[(String, Array[ClusterMetadataFunction]), MetadataError] {
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err(Corrupt("function set asset is not valid JSON: \{e}"))
  }
  let obj = match json {
    Object(obj) => obj
    _ => return Err(Corrupt("function set asset must be a JSON object"))
  }
  for key, _ in obj {
    if key != "name" &&
      key != "version" &&
      key != "revision" &&
      key != "functions" {
      return Err(
        Rejected(
          "asset field '\{key}' is not allowed (name, version, revision, functions)",
        ),
      )
    }
  }
  // mbel's playground documents carry {"version": 1}; accepting it (and
  // only it) keeps that lineage without inventing a second version
  match obj.get("version") {
    Some(Number(1.0)) => ()
    Some(Number(_)) =>
      return Err(Rejected("asset version must be 1 (mbel JSON v1)"))
    Some(_) => return Err(Rejected("asset version must be a number"))
    None => ()
  }
  let set = match
    decode_function_set_doc(
      Json::object(
        {
          let map : Map[String, Json] = {}
          for key, value in obj {
            if key != "version" {
              map[key] = value
            }
          }
          map
        },
      ),
    ) {
    Ok(set) => set
    Err(e) => return Err(e)
  }
  Ok((set.name, set.functions))
}

///|
/// Validates a function set before it becomes metadata. Two layers,
/// stated plainly (P6 evaluation, ticket 36 §评估校核):
///
///   * asset level — set name whitelist, size bounds, unknown fields
///     (at parse), and everything mbel defines about names, parameters
///     and bodies, delegated through `@transform.validate_functions`;
///   * purity — no clock builtin anywhere in the asset (AGENTS §5).
///
/// What this cannot do is type-check the bodies: mbel infers types from
/// call sites. That guarantee is delivered by `compile_with` when a
/// spec actually uses the set, and it is a publish-time rejection
/// there too.
pub fn validate_function_set(
  name : String,
  functions : Array[ClusterMetadataFunction],
) -> Result[Unit, MetadataError] {
  // the project's one name whitelist (core/spec), reused rather than
  // re-spelled: an asset name travels in specs and CLI flags exactly
  // like a topic name does
  if !@spec.valid_topic_name(name) {
    return Err(
      Rejected("invalid function set name '\{name}' (1..128 of [a-z0-9._-])"),
    )
  }
  if functions.length() == 0 {
    return Err(
      Rejected("function set \{name} must define at least one function"),
    )
  }
  if functions.length() > MAX_FUNCTIONS_PER_SET {
    return Err(
      Rejected(
        "function set \{name} has \{functions.length()} functions (max \{MAX_FUNCTIONS_PER_SET})",
      ),
    )
  }
  for f in functions {
    if f.body.length() > MAX_FUNCTION_BODY_CHARS {
      return Err(
        Rejected(
          "function \{f.name}: body is \{f.body.length()} chars (max \{MAX_FUNCTION_BODY_CHARS})",
        ),
      )
    }
    if f.params.length() > MAX_FUNCTION_PARAMS {
      return Err(
        Rejected(
          "function \{f.name}: \{f.params.length()} params (max \{MAX_FUNCTION_PARAMS})",
        ),
      )
    }
  }
  let rules : Array[@transform.RuleFunction] = []
  for f in functions {
    rules.push(@transform.RuleFunction::{
      name: f.name,
      params: f.params,
      body: f.body,
    })
  }
  match @transform.validate_functions(rules) {
    Ok(_) => Ok(())
    Err(e) => Err(Rejected(e))
  }
}

///|
/// Adopts a function set at a revision someone else assigned — the
/// control plane's, when a node pulls one (P11/T54). Unlike a local
/// create, this does not invent a revision: the number means "which
/// version of this asset the authority is serving", and a node that
/// made up its own could not tell whether it was behind.
///
/// Monotonic in the same direction as `create_function_set`: adopting
/// an older revision than the node already holds is refused, because
/// that is a rollback nobody asked for.
pub fn adopt_function_set(
  store : MetadataStore,
  name : String,
  functions : Array[ClusterMetadataFunction],
  revision : Int64,
) -> Result[ClusterMetadataFunctionSet, MetadataError] {
  match validate_function_set(name, functions) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let current = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let sets : Array[ClusterMetadataFunctionSet] = []
  for set in current.function_sets {
    if set.name == name {
      if revision < set.revision {
        return Err(
          Rejected(
            "function set \{name} is at revision \{set.revision} here; refusing to adopt the older \{revision}",
          ),
        )
      }
    } else {
      sets.push(set)
    }
  }
  let adopted = ClusterMetadataFunctionSet::{ name, revision, functions }
  sets.push(adopted)
  let next = ClusterMetadata::{
    topics: current.topics,
    function_sets: sets,
    version: current.version + 1L,
  }
  match (store.save)(next) {
    Ok(_) => Ok(adopted)
    Err(e) => Err(e)
  }
}

///|
fn find_function_set(
  metadata : ClusterMetadata,
  name : String,
) -> ClusterMetadataFunctionSet? {
  for set in metadata.function_sets {
    if set.name == name {
      return Some(set)
    }
  }
  None
}

///|
/// Creates a function set, or updates it in place when the name already
/// exists — the revision moves by one either way. One verb, because an
/// update *is* a new revision of the same asset; the reply says which
/// happened, so an operator never has to guess (README 决策 30).
pub fn create_function_set(
  store : MetadataStore,
  name : String,
  functions : Array[ClusterMetadataFunction],
) -> Result[ClusterMetadataFunctionSet, MetadataError] {
  match validate_function_set(name, functions) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let current = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let sets : Array[ClusterMetadataFunctionSet] = []
  let mut revision = 1L
  for set in current.function_sets {
    if set.name == name {
      revision = set.revision + 1L
    } else {
      sets.push(set)
    }
  }
  let created = ClusterMetadataFunctionSet::{ name, revision, functions }
  sets.push(created)
  let next = ClusterMetadata::{
    topics: current.topics,
    function_sets: sets,
    version: current.version + 1L,
  }
  match (store.save)(next) {
    Ok(_) => Ok(created)
    Err(e) => Err(e)
  }
}

///|
/// Reads one function set by name.
pub fn get_function_set(
  store : MetadataStore,
  name : String,
) -> Result[ClusterMetadataFunctionSet, MetadataError] {
  let metadata = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  match find_function_set(metadata, name) {
    Some(set) => Ok(set)
    None => Err(Rejected("no such function set \{name}"))
  }
}

///|
/// Lists the function sets, name-sorted so two readers agree.
pub fn list_function_sets(
  store : MetadataStore,
) -> Result[Array[ClusterMetadataFunctionSet], MetadataError] {
  let metadata = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let sets : Array[ClusterMetadataFunctionSet] = []
  for set in metadata.function_sets {
    sets.push(set)
  }
  sets.sort_by(fn(a, b) { a.name.compare(b.name) })
  Ok(sets)
}

///|
/// Removes a function set. A spec that still references it fails its
/// next apply — which is the honest outcome: the reference is checked
/// where it is used, never at a distance.
pub fn delete_function_set(
  store : MetadataStore,
  name : String,
) -> Result[Unit, MetadataError] {
  let current = match (store.load)() {
    Ok(metadata) => metadata
    Err(e) => return Err(e)
  }
  let kept : Array[ClusterMetadataFunctionSet] = []
  let mut found = false
  for set in current.function_sets {
    if set.name == name {
      found = true
    } else {
      kept.push(set)
    }
  }
  if !found {
    return Err(Rejected("no such function set \{name}"))
  }
  let next = ClusterMetadata::{
    topics: current.topics,
    function_sets: kept,
    version: current.version + 1L,
  }
  match (store.save)(next) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}
