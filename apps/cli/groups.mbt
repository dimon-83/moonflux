// SPDX-License-Identifier: Apache-2.0
// The control plane's consumer-group registry (P9).
//
// The control plane is the coordinator: members report to it, it decides
// who holds which partition, and it is the only place committed offsets
// live. Membership is in memory and derived from reports (the same
// stance as node liveness); **committed offsets are persisted**, because
// consumer progress is the one thing here that must survive a restart.

///|
/// How many groups a control plane will coordinate. A bound, stated: the
/// registry is loaded, swept and written as one document.
const MAX_GROUPS = 256

///|
struct GroupRegistry {
  data_dir : String
  timeout_ms : Int64
  groups : Array[@group.GroupState]
}

///|
fn groups_path(data_dir : String) -> String {
  "\{data_dir}/groups.json"
}

///|
/// Loads the registry from disk. A corrupt document is fatal: starting
/// with an empty registry would silently reset every consumer group's
/// progress, and "your offsets are somewhere else now" is not a
/// recoverable surprise.
fn GroupRegistry::new(data_dir : String, timeout_ms : Int64) -> GroupRegistry {
  let groups : Array[@group.GroupState] = []
  let path = groups_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => {
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(e) => fail("read \{path}: \{e}")
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      let json = @json.parse(text[0:text.length()]) catch {
        e => fail("corrupt \{path}: \{e}")
      }
      let entries = match json.value("groups") {
        Some(Array(entries)) => entries
        _ => fail("corrupt \{path}: missing groups array")
      }
      for entry in entries {
        let name = match entry.value("name") {
          Some(String(name)) => name
          _ => fail("corrupt \{path}: a group has no name")
        }
        let state = @group.new_group(name)
        state.epoch = match entry.value("epoch") {
          Some(Number(n)) => n.to_int64()
          _ => 0L
        }
        match entry.value("committed") {
          Some(Array(commits)) =>
            for commit in commits {
              let topic = match commit.value("topic") {
                Some(String(topic)) => topic
                _ => continue
              }
              let partition = match commit.value("partition") {
                Some(Number(n)) => n.to_int()
                _ => continue
              }
              let offset = match commit.value("offset") {
                Some(Number(n)) => n.to_int64()
                _ => continue
              }
              state.committed.push(@group.CommitRecord::{
                topic,
                partition,
                offset,
              })
            }
          _ => ()
        }
        groups.push(state)
      }
    }
    _ => ()
  }
  GroupRegistry::{ data_dir, timeout_ms, groups }
}

///|
/// Persists committed offsets and epochs. Atomic (temp + rename) like
/// every other document this project writes: a half-written offset file
/// is worse than no file.
fn GroupRegistry::save(
  self : GroupRegistry,
  state : @group.GroupState,
) -> Result[Unit, String] {
  let commits : Array[Json] = []
  for commit in state.committed {
    let item : Map[String, Json] = {}
    item["topic"] = Json::string(commit.topic)
    item["partition"] = Json::number(commit.partition.to_double())
    item["offset"] = Json::number(commit.offset.to_double())
    commits.push(Json::object(item))
  }
  let groups_json : Array[Json] = []
  for group in self.groups {
    let doc : Map[String, Json] = {}
    doc["name"] = Json::string(group.group)
    doc["epoch"] = Json::number(group.epoch.to_double())
    if group.group == state.group {
      doc["committed"] = Json::array(commits)
    } else {
      let existing : Array[Json] = []
      for commit in group.committed {
        let item : Map[String, Json] = {}
        item["topic"] = Json::string(commit.topic)
        item["partition"] = Json::number(commit.partition.to_double())
        item["offset"] = Json::number(commit.offset.to_double())
        existing.push(Json::object(item))
      }
      doc["committed"] = Json::array(existing)
    }
    groups_json.push(Json::object(doc))
  }
  let root : Map[String, Json] = {}
  root["version"] = Json::number(1.0)
  root["groups"] = Json::array(groups_json)
  let text = Json::object(root).stringify(indent=2)
  match @fs.mkdirs(self.data_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{self.data_dir}: \{e}")
  }
  let path = groups_path(self.data_dir)
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
fn GroupRegistry::find(
  self : GroupRegistry,
  group : String,
) -> @group.GroupState? {
  for state in self.groups {
    if state.group == group {
      return Some(state)
    }
  }
  None
}

///|
fn GroupRegistry::ensure(
  self : GroupRegistry,
  group : String,
) -> @group.GroupState {
  match self.find(group) {
    Some(state) => state
    None => {
      let state = @group.new_group(group)
      self.groups.push(state)
      state
    }
  }
}

///|
/// The partition index a directory entry under `topics/<topic>` names,
/// if it names one at all. Both layouts count: the segmented
/// `partition-<N>/` directory and the pre-P8 `partition-<N>.log` single
/// file (migrated by the next open, but the truth about disk until
/// then). Anything else names no partition.
fn partition_index_of(entry : String) -> Int? {
  if !entry.has_prefix("partition-") {
    return None
  }
  let rest = entry["partition-".length():entry.length()]
  let rest = if rest.has_suffix(".log") {
    rest[0:rest.length() - ".log".length()]
  } else {
    rest
  }
  match (try? @string.parse_int(rest[0:rest.length()])) {
    Ok(index) => Some(index)
    Err(_) => None
  }
}

///|
/// One past the highest partition index that exists on disk. Counting
/// entries would lie whenever a produce addressed an index past a hole
/// — `produce --partition 3` creates partition-3 and nothing else — so
/// this is a max, not a count. An unlistable directory reads as zero:
/// the control plane's data dir hosts no logs, and that is its normal
/// shape, not a failure.
fn disk_partition_end(data_dir : String, topic : String) -> Int {
  let topic_dir = "\{data_dir}/topics/\{topic}"
  let mut highest = -1
  match @fs.list_dir(topic_dir) {
    Ok(entries) =>
      for entry in entries {
        match partition_index_of(entry) {
          Some(index) => if index > highest { highest = index }
          None => ()
        }
      }
    Err(_) => ()
  }
  highest + 1
}

///|
/// The partitions a group's declared topics cover, from the
/// coordinator's own view of the world: a topic's partition count is
/// the **larger** of what is declared and what exists on disk, because
/// the two hosts of this registry disagree about where topics come
/// from. The control plane only knows declarations (produce there
/// auto-creates nothing); a standalone broker's produce auto-creates
/// without declaring (P18) — an enumeration that ignored its disk
/// would hand a group an empty share for the very topics the broker
/// actually has. A topic that appears in neither contributes nothing,
/// which is the honest answer: there is nowhere to read from until
/// someone declares (or produces to) it.
fn group_partitions(
  data_dir : String,
  topics : Array[String],
  store : MetadataStore,
) -> Array[@cluster.PartitionId] {
  let declarations = match list_topics(store) {
    Ok(topics) => topics
    Err(_) => []
  }
  let out : Array[@cluster.PartitionId] = []
  for topic in topics {
    let mut count = 0
    for decl in declarations {
      if decl.name == topic {
        count = decl.partitions
      }
    }
    let disk = disk_partition_end(data_dir, topic)
    if disk > count {
      count = disk
    }
    for i = 0; i < count; i = i + 1 {
      out.push(@cluster.PartitionId::{ topic, index: i })
    }
  }
  out
}

///|
/// The view a member gets back: its epoch, its share, and where each of
/// its partitions stands. Built the same way for join and heartbeat —
/// they differ only in what they record, not in what they answer.
fn GroupRegistry::view_of(
  self : GroupRegistry,
  state : @group.GroupState,
  member : String,
  store : MetadataStore,
) -> @client.GroupView {
  let partitions = group_partitions(self.data_dir, state.topics, store)
  let mine = @group.assignment_of(state, member, partitions)
  let wire : Array[@client.WireGroupPartition] = []
  for p in mine {
    wire.push(@client.WireGroupPartition::{
      topic: p.topic,
      partition: p.index,
      committed: @group.resume_offset(state, p),
    })
  }
  @client.GroupView::{
    group: state.group,
    epoch: state.epoch,
    timeout_ms: self.timeout_ms,
    partitions: wire,
    members: state.members.length(),
  }
}

///|
fn GroupRegistry::join(
  self : GroupRegistry,
  join : @client.GroupJoin,
  store : MetadataStore,
  now_ms : Int64,
) -> Result[@client.GroupView, String] {
  if self.groups.length() >= MAX_GROUPS && self.find(join.group) is None {
    return Err("too many groups (\{MAX_GROUPS})")
  }
  let member = @group.GroupMember::{
    id: join.member.id,
    address: join.member.address,
    last_seen_ms: now_ms,
  }
  let state = self.ensure(join.group)
  let joined = @group.observe_member(state, member)
  let declared = @group.declare_topics(state, join.topics)
  if joined || declared {
    match self.save(state) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(self.view_of(state, join.member.id, store))
}

///|
fn GroupRegistry::heartbeat(
  self : GroupRegistry,
  beat : @client.GroupHeartbeat,
  store : MetadataStore,
  now_ms : Int64,
) -> Result[@client.GroupView, String] {
  let state = match self.find(beat.group) {
    Some(state) => state
    None =>
      return Err(
        "\{beat.member.id} is not a member of \{beat.group}: the group does not exist",
      )
  }
  let member = @group.GroupMember::{
    id: beat.member.id,
    address: beat.member.address,
    last_seen_ms: now_ms,
  }
  let joined = @group.observe_member(state, member)
  if joined {
    match self.save(state) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(self.view_of(state, beat.member.id, store))
}

///|
/// A graceful departure: the member goes now instead of waiting for its
/// silence to be noticed, so the rebalance starts immediately.
fn GroupRegistry::leave(
  self : GroupRegistry,
  group : String,
  member : String,
) -> Result[Unit, String] {
  let state = match self.find(group) {
    Some(state) => state
    None => return Ok(()) // leaving a group that is gone is not an error
  }
  let kept : Array[@group.GroupMember] = []
  let mut left = false
  for existing in state.members {
    if existing.id == member {
      left = true
    } else {
      kept.push(existing)
    }
  }
  if left {
    state.members.clear()
    for existing in kept {
      state.members.push(existing)
    }
    state.epoch += 1L
    match self.save(state) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    note("\{member} left group \{group}; generation is now \{state.epoch}")
  }
  Ok(())
}

///|
fn GroupRegistry::commit(
  self : GroupRegistry,
  commit : @client.GroupCommit,
  store : MetadataStore,
) -> Result[Unit, String] {
  let state = match self.find(commit.group) {
    Some(state) => state
    None => return Err("no such group \{commit.group}")
  }
  let partitions = group_partitions(self.data_dir, state.topics, store)
  let mine = @group.assignment_of(state, commit.member, partitions)
  let partition = @cluster.PartitionId::{
    topic: commit.topic,
    index: commit.partition,
  }
  match
    @group.commit(
      state,
      commit.member,
      commit.epoch,
      partition,
      commit.offset,
      mine,
    ) {
    Ok(_) => ()
    Err(e) => return Err("\{e}")
  }
  match self.save(state) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok(())
}

///|
/// Drops members that have gone silent. Returns `(group, member)` pairs
/// so the caller reports each departure once.
fn GroupRegistry::sweep(
  self : GroupRegistry,
  now_ms : Int64,
) -> Array[(String, String)] {
  let gone : Array[(String, String)] = []
  for state in self.groups {
    let left = @group.sweep(state, now_ms, self.timeout_ms)
    for member in left {
      gone.push((state.group, member))
    }
    if left.length() > 0 {
      match self.save(state) {
        Ok(_) => ()
        Err(e) => note("warning: cannot persist group \{state.group}: \{e}")
      }
    }
  }
  gone
}

///|
fn GroupRegistry::describe(
  self : GroupRegistry,
  group : String,
) -> Result[@client.GroupDescription, String] {
  let state = match self.find(group) {
    Some(state) => state
    None => return Err("no such group \{group}")
  }
  let members : Array[@client.WireGroupMember] = []
  for member in state.members {
    members.push(@client.WireGroupMember::{
      id: member.id,
      address: member.address,
    })
  }
  let commits : Array[@client.WireGroupPartition] = []
  for commit in state.committed {
    commits.push(@client.WireGroupPartition::{
      topic: commit.topic,
      partition: commit.partition,
      committed: commit.offset,
    })
  }
  Ok(@client.GroupDescription::{
    group: state.group,
    epoch: state.epoch,
    members,
    commits,
  })
}

///|
/// The oldest offset any group still needs, per partition — the floor
/// retention may not delete below. Only groups that have actually
/// committed participate: a group that never committed is not "behind",
/// it has not started, and holding the whole log for it would mean
/// never deleting anything (a consumer that starts after the data is
/// gone gets a structured offset-out-of-range, which is the standard
/// answer and the honest one).
fn GroupRegistry::floors(
  self : GroupRegistry,
  partitions : Array[@cluster.PartitionId],
) -> Array[@client.GroupFloor] {
  let out : Array[@client.GroupFloor] = []
  for partition in partitions {
    let mut best : Int64? = None
    for state in self.groups {
      // only groups that declared this topic can constrain it
      if !state.topics.contains(partition.topic) {
        continue
      }
      let mut committed : Int64? = None
      for record in state.committed {
        if record.topic == partition.topic &&
          record.partition == partition.index {
          committed = Some(record.offset)
        }
      }
      match committed {
        Some(offset) =>
          match best {
            None => best = Some(offset)
            Some(current) => if offset < current { best = Some(offset) }
          }
        None => ()
      }
    }
    match best {
      Some(floor) =>
        out.push(@client.GroupFloor::{
          topic: partition.topic,
          partition: partition.index,
          floor,
        })
      None => ()
    }
  }
  out
}

///|
/// Every group with its epoch and commit count, for `group list`.
fn GroupRegistry::list(
  self : GroupRegistry,
) -> Array[(String, Int64, Int, Int)] {
  let out : Array[(String, Int64, Int, Int)] = []
  for state in self.groups {
    out.push(
      (
        state.group,
        state.epoch,
        state.members.length(),
        state.committed.length(),
      ),
    )
  }
  out.sort_by(fn(a, b) { a.0.compare(b.0) })
  out
}
