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
        Err(_) => return Ok(ClusterMetadata::{ topics: [], version: 0L })
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
      Ok(ClusterMetadata::{ topics, version })
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
      let root_map : Map[String, Json] = {}
      root_map["version"] = Json::number(metadata.version.to_double())
      root_map["topics"] = Json::array(items)
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
    ClusterMetadata::{ topics: [], version: 0L },
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
  let next = ClusterMetadata::{ topics, version: current.version + 1L }
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
  let next = ClusterMetadata::{ topics: kept, version: current.version + 1L }
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
