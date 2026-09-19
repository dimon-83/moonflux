// SPDX-License-Identifier: Apache-2.0
// core/client: the client's kernel side - frame codec, session state
// machine, and the command semantics, with **transport injected**.
//
// This lives in the kernel rather than in apps/ for one reason: the
// browser editor needs the same client logic the CLI uses, and a
// browser cannot open a TCP socket. Keeping it here means one
// implementation of the protocol runs over native TCP, over a
// WebSocket, and over a socketpair in tests (AGENTS §1 rule 2). It is
// pure computation - no IO, no clock, no platform dependency - so it
// compiles for every backend including wasm-gc.
//
// The transport contract is `Conn`: a bidirectional, ordered,
// reliable byte pipe. Whoever owns a socket provides one.

///|
pub const PROTOCOL_VERSION = 2

///|
pub const CMD_HELLO = 1

///|
pub const CMD_WELCOME = 2

///|
pub const CMD_PRODUCE = 3

///|
pub const CMD_FETCH = 4

///|
pub const CMD_OK = 5

///|
pub const CMD_ERR = 6

// Control-plane commands (P3). They ride the same framing so a node
// speaks one protocol whether it is serving data or cluster state;
// an old peer answers ERR(unknown-command) rather than dropping the
// connection, which is the whole point of having a version byte.

///|
/// A node announcing itself to the control plane: id, role, address.
pub const CMD_REGISTER = 7

///|
/// Liveness plus progress: the same node record, resent on a timer.
pub const CMD_HEARTBEAT = 8

///|
/// Reads the control plane's node table.
pub const CMD_NODES = 9

///|
/// Asks the control plane who leads a partition. Placement and
/// elections are the control plane's decisions; data nodes ask
/// rather than guess.
pub const CMD_LEADER = 10

///|
/// Follower-pull replication: "send me your log bytes from offset X".
/// The reply carries whole frames verbatim plus the leader's
/// watermarks, so the follower stores exactly what the leader stored.
pub const CMD_SYNC_FETCH = 11

///|
/// A follower telling its leader how far it has got. The leader
/// derives the high watermark from these reports (core/replica
/// owns the arithmetic; this command is only its transport).
pub const CMD_SYNC_ACK = 12

///|
/// Reads a partition's watermark pair (HW/LEO) from its leader.
pub const CMD_OFFSET_INFO = 13

///|
/// A candidate telling the control plane it has taken a partition.
/// Authority still arrives only by nomination — the control plane
/// advertises the nomination in its leader reply (see `PartitionView`)
/// rather than calling out, because a control plane that dials data
/// nodes can be blocked by a busy one, and no node should be able to
/// hang the cluster's brain.
pub const CMD_CONFIRM = 14

///|
/// Metadata verbs: declare a topic, read back what has been declared,
/// undeclare one. Authors state intent; the control plane turns it
/// into placement on the next reconcile. There is deliberately no
/// "create partitions" command — that would be an event, and this
/// design is level-triggered.
pub const CMD_TOPIC_CREATE = 15

///|
pub const CMD_TOPIC_LIST = 16

///|
pub const CMD_TOPIC_DELETE = 17

///|
/// A read that stops at the high watermark: the same request shape as
/// FETCH, but the reply also carries the watermarks that bounded it.
/// Additive on purpose — `FETCH` keeps its exact reply shape, so this
/// closes the read-mode gap without a protocol version bump (the frame
/// version gates *incompatible* changes, and nobody's parser needed to
/// change to keep working).
pub const CMD_FETCH_COMMITTED = 18

///|
/// Partition-aware data commands. The original PRODUCE/FETCH keep
/// their exact payloads and mean partition 0 — every pre-P5 client and
/// every golden script relies on that — so partitioning lands as new
/// commands rather than new fields in old payloads (the same additive
/// rule the committed read followed).
pub const CMD_PRODUCE_PARTITION = 20

///|
pub const CMD_FETCH_PARTITION = 21

///|
/// Function-set assets (P6): the rule assets a pipeline's expression
/// transforms can reference. Same additive pattern as the topic verbs —
/// a control-plane asset with create/list/get/delete, carried as JSON
/// text so the asset document is the payload (nothing about the
/// document shape belongs in the frame layer).
pub const CMD_FUNCTION_SET_CREATE = 22

///|
pub const CMD_FUNCTION_SET_LIST = 23

///|
pub const CMD_FUNCTION_SET_GET = 24

///|
pub const CMD_FUNCTION_SET_DELETE = 25

///|
/// Storage introspection (P8): the segments a partition is made of.
/// Additive like every other read-only question — the answer is the
/// node's own view of its disk, asked of whoever holds the partition.
pub const CMD_SEGMENTS = 26

///|
/// Consumer groups (P9). Additive like the other control commands: the
/// coordinator is the control plane, membership reports are heartbeats,
/// and the assignment travels in the reply — the same shape as
/// placements and nominations, for the same reason (state on the reply
/// channel the member already polls).
pub const CMD_GROUP_JOIN = 27

///|
pub const CMD_GROUP_HEARTBEAT = 28

///|
pub const CMD_GROUP_LEAVE = 29

///|
pub const CMD_GROUP_COMMIT = 30

///|
pub const CMD_GROUP_DESCRIBE = 31

///|
/// A group-protocol refusal that is not a transport or payload problem:
/// a stale epoch, an unknown member, a partition the member does not
/// hold, or a regression. The message says which.
pub const ERR_GROUP = 8

///|
/// The server requires authentication and this connection has not
/// presented a credential (or presented a bad one). Distinct from
/// `ERR_FORBIDDEN`: one means "say who you are", the other means "not
/// you".
pub const ERR_AUTH_REQUIRED = 9

///|
/// Authenticated, and not allowed to do this.
pub const ERR_FORBIDDEN = 10

///|
/// Authentication (P12): the credential exchange that happens right
/// after HELLO/WELCOME, before any command is served. A command, not a
/// HELLO field: the handshake payload is a *version*, and overloading it
/// would make two concerns share one parse.
pub const CMD_AUTH = 35

///|
/// One member as it travels: who it is and where it can be reached.
pub(all) struct WireGroupMember {
  id : String
  address : String
} derive(Debug, Eq, Show)

///|
/// A join (or the initial declaration): the group, the member, and the
/// topics it wants to consume.
pub(all) struct GroupJoin {
  group : String
  member : WireGroupMember
  topics : Array[String]
} derive(Debug, Eq, Show)

///|
pub fn encode_group_join(join : GroupJoin) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, join.group)
  write_field(buf, join.member.id)
  write_field(buf, join.member.address)
  buf.write_leb128(join.topics.length())
  for topic in join.topics {
    write_field(buf, topic)
  }
  buf.to_bytes()
}

///|
pub fn decode_group_join(payload : Bytes) -> Result[GroupJoin, String] {
  let reader = @codec.Reader::new(payload)
  let group = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if group.length() == 0 {
    return Err("group name must not be empty")
  }
  let id = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if id.length() == 0 {
    return Err("member id must not be empty")
  }
  let address = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated topic count")
  }
  let topics : Array[String] = []
  for _i = 0; _i < count; _i = _i + 1 {
    let topic = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    topics.push(topic)
  }
  Ok(GroupJoin::{ group, member: WireGroupMember::{ id, address }, topics })
}

///|
/// A heartbeat is the same report as a join, without the declaration:
/// the topics were settled at join, and repeating them would let a
/// silent member re-declare the world every tick.
pub(all) struct GroupHeartbeat {
  group : String
  member : WireGroupMember
} derive(Debug, Eq, Show)

///|
pub fn encode_group_heartbeat(beat : GroupHeartbeat) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, beat.group)
  write_field(buf, beat.member.id)
  write_field(buf, beat.member.address)
  buf.to_bytes()
}

///|
pub fn decode_group_heartbeat(
  payload : Bytes,
) -> Result[GroupHeartbeat, String] {
  let reader = @codec.Reader::new(payload)
  let group = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let id = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let address = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok(GroupHeartbeat::{ group, member: WireGroupMember::{ id, address } })
}

///|
/// A commit: the member, the epoch it believes in, and where it got to
/// on one partition. One partition per message keeps the fence
/// meaningful — a batch spanning partitions could half-apply.
pub(all) struct GroupCommit {
  group : String
  member : String
  epoch : Int64
  topic : String
  partition : Int
  offset : Int64
} derive(Debug, Eq, Show)

///|
pub fn encode_group_commit(commit : GroupCommit) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, commit.group)
  write_field(buf, commit.member)
  buf.write_leb128(commit.epoch)
  write_field(buf, commit.topic)
  buf.write_leb128(commit.partition)
  buf.write_leb128(commit.offset)
  buf.to_bytes()
}

///|
pub fn decode_group_commit(payload : Bytes) -> Result[GroupCommit, String] {
  let reader = @codec.Reader::new(payload)
  let group = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let member = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let epoch = match reader.read_uleb128() {
    Ok(v) => v.reinterpret_as_int64()
    Err(_) => return Err("truncated epoch")
  }
  let topic = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let partition = match reader.read_uleb128_len() {
    Ok(v) => v
    Err(_) => return Err("truncated partition")
  }
  let offset = match reader.read_uleb128() {
    Ok(v) => v.reinterpret_as_int64()
    Err(_) => return Err("truncated offset")
  }
  Ok(GroupCommit::{ group, member, epoch, topic, partition, offset })
}

///|
/// What a member learns from its coordinator: the epoch it must commit
/// against, the partitions it holds, the coordinated liveness timeout
/// (so heartbeats are paced by the coordinator's clock, not the
/// member's guess), and how far each of its partitions got.
pub(all) struct GroupView {
  group : String
  epoch : Int64
  timeout_ms : Int64
  partitions : Array[WireGroupPartition]
  members : Int
} derive(Debug, Eq, Show)

///|
pub(all) struct WireGroupPartition {
  topic : String
  partition : Int
  /// the offset this member should resume from
  committed : Int64
} derive(Debug, Eq, Show)

///|
pub fn encode_group_view(view : GroupView) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, view.group)
  buf.write_leb128(view.epoch)
  buf.write_leb128(view.timeout_ms)
  buf.write_leb128(view.members)
  buf.write_leb128(view.partitions.length())
  for p in view.partitions {
    write_field(buf, p.topic)
    buf.write_leb128(p.partition)
    buf.write_leb128(p.committed)
  }
  buf.to_bytes()
}

///|
pub fn decode_group_view(payload : Bytes) -> Result[GroupView, String] {
  let reader = @codec.Reader::new(payload)
  let group = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let epoch = match reader.read_uleb128() {
    Ok(v) => v.reinterpret_as_int64()
    Err(_) => return Err("truncated epoch")
  }
  let timeout_ms = match reader.read_uleb128() {
    Ok(v) => v.reinterpret_as_int64()
    Err(_) => return Err("truncated timeout")
  }
  let members = match reader.read_uleb128_len() {
    Ok(v) => v
    Err(_) => return Err("truncated member count")
  }
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated partition count")
  }
  let partitions : Array[WireGroupPartition] = []
  for _i = 0; _i < count; _i = _i + 1 {
    let topic = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let partition = match reader.read_uleb128_len() {
      Ok(v) => v
      Err(_) => return Err("truncated partition")
    }
    let committed = match reader.read_uleb128() {
      Ok(v) => v.reinterpret_as_int64()
      Err(_) => return Err("truncated committed offset")
    }
    partitions.push(WireGroupPartition::{ topic, partition, committed })
  }
  Ok(GroupView::{ group, epoch, timeout_ms, partitions, members })
}

///|
/// One group as an operator sees it: who is in it, and how far each
/// partition got. Deleted groups are reported by absence.
pub(all) struct GroupDescription {
  group : String
  epoch : Int64
  members : Array[WireGroupMember]
  commits : Array[WireGroupPartition]
} derive(Debug, Eq, Show)

///|
pub fn encode_group_description(desc : GroupDescription) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, desc.group)
  buf.write_leb128(desc.epoch)
  buf.write_leb128(desc.members.length())
  for member in desc.members {
    write_field(buf, member.id)
    write_field(buf, member.address)
  }
  buf.write_leb128(desc.commits.length())
  for commit in desc.commits {
    write_field(buf, commit.topic)
    buf.write_leb128(commit.partition)
    buf.write_leb128(commit.committed)
  }
  buf.to_bytes()
}

///|
pub fn decode_group_description(
  payload : Bytes,
) -> Result[GroupDescription, String] {
  let reader = @codec.Reader::new(payload)
  let group = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let epoch = match reader.read_uleb128() {
    Ok(v) => v.reinterpret_as_int64()
    Err(_) => return Err("truncated epoch")
  }
  let member_count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated member count")
  }
  let members : Array[WireGroupMember] = []
  for _i = 0; _i < member_count; _i = _i + 1 {
    let id = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let address = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    members.push(WireGroupMember::{ id, address })
  }
  let commit_count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated commit count")
  }
  let commits : Array[WireGroupPartition] = []
  for _i = 0; _i < commit_count; _i = _i + 1 {
    let topic = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let partition = match reader.read_uleb128_len() {
      Ok(v) => v
      Err(_) => return Err("truncated partition")
    }
    let committed = match reader.read_uleb128() {
      Ok(v) => v.reinterpret_as_int64()
      Err(_) => return Err("truncated committed offset")
    }
    commits.push(WireGroupPartition::{ topic, partition, committed })
  }
  Ok(GroupDescription::{ group, epoch, members, commits })
}

///|
/// One segment as the wire reports it.
pub(all) struct WireSegment {
  base : Int64
  records : Int64
  bytes : Int
} derive(Debug, Eq, Show)

///|
pub fn encode_wire_segments(segments : Array[WireSegment]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(segments.length())
  for seg in segments {
    buf.write_leb128(seg.base)
    buf.write_leb128(seg.records)
    buf.write_leb128(seg.bytes)
  }
  buf.to_bytes()
}

///|
pub fn decode_wire_segments(
  payload : Bytes,
) -> Result[Array[WireSegment], String] {
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated segment count")
  }
  let out : Array[WireSegment] = []
  for _i = 0; _i < count; _i = _i + 1 {
    let base = match reader.read_uleb128() {
      Ok(base) => base.reinterpret_as_int64()
      Err(_) => return Err("truncated segment base")
    }
    let records = match reader.read_uleb128() {
      Ok(records) => records.reinterpret_as_int64()
      Err(_) => return Err("truncated segment record count")
    }
    let bytes = match reader.read_uleb128_len() {
      Ok(bytes) => bytes
      Err(_) => return Err("truncated segment byte count")
    }
    out.push(WireSegment::{ base, records, bytes })
  }
  Ok(out)
}

///|
/// One rewritten segment, as the wire carries it: the numbers an
/// operator reads to decide whether the pass was worth its IO.
pub(all) struct WireCompaction {
  base : Int64
  frames_before : Int
  frames_after : Int
  dropped_records : Int
  bytes_before : Int
  bytes_after : Int
} derive(Debug, Eq, Show)

///|
pub fn encode_wire_compactions(entries : Array[WireCompaction]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(entries.length())
  for entry in entries {
    buf.write_leb128(entry.base)
    buf.write_leb128(entry.frames_before)
    buf.write_leb128(entry.frames_after)
    buf.write_leb128(entry.dropped_records)
    buf.write_leb128(entry.bytes_before)
    buf.write_leb128(entry.bytes_after)
  }
  buf.to_bytes()
}

///|
pub fn decode_wire_compactions(
  payload : Bytes,
) -> Result[Array[WireCompaction], String] {
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated compaction count")
  }
  let out : Array[WireCompaction] = []
  for _i = 0; _i < count; _i = _i + 1 {
    let base = match reader.read_uleb128() {
      Ok(base) => base.reinterpret_as_int64()
      Err(_) => return Err("truncated compaction base")
    }
    let frames_before = match reader.read_uleb128_len() {
      Ok(value) => value
      Err(_) => return Err("truncated compaction frame count")
    }
    let frames_after = match reader.read_uleb128_len() {
      Ok(value) => value
      Err(_) => return Err("truncated compaction frame count")
    }
    let dropped_records = match reader.read_uleb128_len() {
      Ok(value) => value
      Err(_) => return Err("truncated compaction drop count")
    }
    let bytes_before = match reader.read_uleb128_len() {
      Ok(value) => value
      Err(_) => return Err("truncated compaction byte count")
    }
    let bytes_after = match reader.read_uleb128_len() {
      Ok(value) => value
      Err(_) => return Err("truncated compaction byte count")
    }
    out.push(WireCompaction::{
      base,
      frames_before,
      frames_after,
      dropped_records,
      bytes_before,
      bytes_after,
    })
  }
  if reader.remaining() > 0 {
    return Err("trailing bytes after compactions")
  }
  Ok(out)
}

///|
/// Deploys a pipeline document to the broker: the same work
/// `pipeline apply` does locally (validate, compile, persist), so the
/// editor can close its loop - drag a pipeline, deploy it, produce,
/// consume - without shelling out. Validation and compilation stay in
/// the kernel; this command only carries the document.
pub const CMD_APPLY_PIPELINE = 19

///|
/// Keyed compaction (P14): drop the records below the committed floor
/// whose key occurs again below it, keeping every survivor's offset.
/// Asked of the node that **leads** the partition — this command
/// deletes data, so unlike `CMD_SEGMENTS` a follower may not answer it,
/// and the permission table lists it as a write.
pub const CMD_COMPACT = 36

// Stable error codes (client-visible contract).

///|
pub const ERR_UNSUPPORTED_VERSION = 1

///|
pub const ERR_UNKNOWN_COMMAND = 2

///|
pub const ERR_BAD_PAYLOAD = 3

///|
pub const ERR_STORAGE = 4

///|
pub const ERR_TRANSFORM = 5

///|
pub const ERR_SEQUENCE = 6

///|
/// The peer is registered but the request does not apply to its role
/// (e.g. a data command sent to the control plane's control port).
pub const ERR_WRONG_ROLE = 7

///|
pub const MAX_FRAME_PAYLOAD = 33554432

///|
pub(all) struct Frame {
  cmd : Int
  rid : Int
  payload : Bytes
} derive(Debug, Eq, Show)

///|
/// Encodes one frame.
pub fn encode_frame(frame : Frame) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MFS"[0:3])
  out.write_byte(b'\x02')
  out.write_byte(frame.cmd.to_byte())
  out.write_uint_be(frame.rid.reinterpret_as_uint())
  out.write_uint_be(frame.payload.length().reinterpret_as_uint())
  out.write_bytes(frame.payload[0:frame.payload.length()])
  out.to_bytes()
}

///|
/// Parses a frame header (13 bytes). The payload length is validated
/// against the frame limit but the payload bytes are NOT included.
pub fn decode_header(header : Bytes) -> Result[(Int, Int, Int), String] {
  if header.length() != 13 {
    return Err("short frame header")
  }
  if header[0] != b'M' || header[1] != b'F' || header[2] != b'S' {
    return Err("bad frame magic")
  }
  let version = header[3].to_int()
  if version != PROTOCOL_VERSION {
    return Err("unsupported frame version \{version}")
  }
  let cmd = header[4].to_int()
  let reader = @codec.Reader::new(header)
  let _ = reader.read_bytes(5)
  let rid = match reader.read_u32_be() {
    Ok(rid) => rid.reinterpret_as_int()
    Err(_) => return Err("bad frame header")
  }
  let len = match reader.read_u32_be() {
    Ok(len) => len.reinterpret_as_int()
    Err(_) => return Err("bad frame header")
  }
  if len < 0 || len > MAX_FRAME_PAYLOAD {
    return Err("frame payload out of bounds")
  }
  Ok((cmd, rid, len))
}

///|
/// HELLO/WELCOME payload: major + minor version.
pub fn encode_hello(major : Int, minor : Int) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_uint_be(major.reinterpret_as_uint())
  out.write_uint_be(minor.reinterpret_as_uint())
  out.to_bytes()
}

///|
pub fn decode_hello(payload : Bytes) -> Result[(Int, Int), String] {
  let reader = @codec.Reader::new(payload)
  let major = match reader.read_u32_be() {
    Ok(v) => v.reinterpret_as_int()
    Err(_) => return Err("bad hello payload")
  }
  let minor = match reader.read_u32_be() {
    Ok(v) => v.reinterpret_as_int()
    Err(_) => return Err("bad hello payload")
  }
  Ok((major, minor))
}

///|
/// Error payload: u16 code + message.
pub fn encode_error(code : Int, message : String) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_uint_be(code.reinterpret_as_uint())
  let msg = @utf8.encode(message[0:message.length()])
  out.write_bytes(msg[0:msg.length()])
  out.to_bytes()
}

///|
pub fn decode_error(payload : Bytes) -> (Int, String) {
  let reader = @codec.Reader::new(payload)
  let code = match reader.read_u32_be() {
    Ok(code) => code.reinterpret_as_int()
    Err(_) => return (-1, "malformed error payload")
  }
  let rest = match reader.read_bytes(reader.remaining()) {
    Ok(rest) => rest
    Err(_) => b""
  }
  (code, @utf8.decode_lossy(rest[0:rest.length()]))
}

// ---------------------------------------------------------------------
// Control-plane payloads (P3): a node's self-description and the
// progress it reports. Encoded as uleb128-length-prefixed UTF-8
// fields + a varint offset, matching the wire protocol's conventions
// (no JSON on the wire; the on-disk forms use JSON, the network does
// not, and a node's identity is data this project must be able to
// compare byte for byte in tests).

///|
/// The role a node plays in a cluster.
pub(all) enum NodeRole {
  /// Control plane: owns cluster metadata and elections.
  Sc
  /// Data plane: owns partition logs and serves produce/fetch.
  Spu
} derive(Debug, Eq, Show)

///|
/// Parses a role name; unknown names are rejected rather than
/// defaulted, so a typo cannot silently produce a data node.
pub fn parse_node_role(s : String) -> Result[NodeRole, String] {
  match s {
    "sc" => Ok(Sc)
    "spu" => Ok(Spu)
    _ => Err("unknown role '\{s}' (expected sc or spu)")
  }
}

///|
/// The wire spelling of a role.
pub fn role_name(role : NodeRole) -> String {
  match role {
    Sc => "sc"
    Spu => "spu"
  }
}

///|
/// What a node tells the control plane about itself. `leo` is the
/// node's own log end for the partition it is reporting on — empty
/// for a freshly started node or a control node, since progress is
/// per partition and this record is per node (§T21 scope: one
/// partition per topic, so a single LEO suffices and the per-partition
/// shape arrives with the placement work in T24).
pub(all) struct NodeRecord {
  id : String
  role : NodeRole
  address : String
  leo : Int64
} derive(Debug, Eq, Show)

///|
fn write_field(buf : @buffer.Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s[0:s.length()])
  buf.write_leb128(bytes.length())
  buf.write_bytes(bytes[0:bytes.length()])
}

///|
fn read_field(reader : @codec.Reader) -> Result[String, String] {
  let len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(_) => return Err("truncated string field")
  }
  match reader.read_bytes(len) {
    Ok(bytes) => Ok(@utf8.decode_lossy(bytes[0:bytes.length()]))
    Err(_) => Err("truncated string field")
  }
}

///|
/// Encodes a node record. Deterministic: same record, same bytes.
pub fn encode_node(record : NodeRecord) -> Bytes {
  // the sectionless form: what a node sends when it has no partition
  // reports to make (and what every pre-P7 caller expects)
  let buf : Array[PartitionReport] = []
  encode_node_full(record, buf)
}

///|
/// Decodes a node record; any malformed input is a structured error,
/// never a partially-filled record.
pub fn decode_node(payload : Bytes) -> Result[NodeRecord, String] {
  // the sectionless view of the same payload: callers that do not care
  // about per-partition reports keep this signature
  match decode_node_full(payload) {
    Ok((record, _reports)) => Ok(record)
    Err(e) => Err(e)
  }
}

///|
/// Encodes the node table reply: uleb128 count, then one node record
/// per entry (each length-prefixed).
pub fn encode_nodes(records : Array[NodeRecord]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(records.length())
  for record in records {
    let bytes = encode_node(record)
    buf.write_leb128(bytes.length())
    buf.write_bytes(bytes[0:bytes.length()])
  }
  buf.to_bytes()
}

///|
/// Decodes the node table reply.
pub fn decode_nodes(payload : Bytes) -> Result[Array[NodeRecord], String] {
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated node table")
  }
  let out : Array[NodeRecord] = []
  for _ in 0..<count {
    let len = match reader.read_uleb128_len() {
      Ok(len) => len
      Err(_) => return Err("truncated node table entry")
    }
    let bytes = match reader.read_bytes(len) {
      Ok(bytes) => bytes
      Err(_) => return Err("truncated node table entry")
    }
    match decode_node(bytes) {
      Ok(record) => out.push(record)
      Err(e) => return Err("bad node record: \{e}")
    }
  }
  Ok(out)
}

// ---------------------------------------------------------------------
// Replication payloads (P3): what a follower asks for and what a
// leader answers with. Offsets travel as be64 (the wire protocol's
// convention for offsets), counts as uleb128.

///|
/// Which partition a replication request is about. One partition per
/// topic for now; the struct exists so the command does not have to
/// change shape when placement starts spreading partitions across
/// nodes (T24).
pub(all) struct PartitionRef {
  topic : String
  partition : Int
} derive(Debug, Eq, Show)

///|
/// A SYNC_FETCH request: the partition and the offset to resume from.
pub(all) struct SyncRequest {
  partition : PartitionRef
  from : Int64
  max_records : Int
} derive(Debug, Eq, Show)

///|
pub fn encode_sync_request(request : SyncRequest) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, request.partition.topic)
  buf.write_leb128(request.partition.partition)
  buf.write_int64_be(request.from)
  buf.write_leb128(request.max_records)
  buf.to_bytes()
}

///|
pub fn decode_sync_request(payload : Bytes) -> Result[SyncRequest, String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  if !@spec.valid_topic_name(topic) {
    return Err("invalid topic name '\{topic}'")
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  let from = match reader.read_i64_be() {
    Ok(from) => from
    Err(_) => return Err("truncated offset")
  }
  let max_records = match reader.read_uleb128_len() {
    Ok(max_records) => max_records
    Err(_) => return Err("truncated record count")
  }
  if from < 0L || max_records <= 0 {
    return Err("negative offset or non-positive record count")
  }
  Ok(SyncRequest::{
    partition: PartitionRef::{ topic, partition },
    from,
    max_records,
  })
}

///|
/// A leader's answer: raw frame bytes plus the watermarks that were
/// current when they were read. `base_offset` is where the bytes
/// start, so the follower can check it is not being handed a hole.
pub(all) struct SyncResponse {
  base_offset : Int64
  record_count : Int
  high_watermark : Int64
  log_end_offset : Int64
  /// concatenated frames, byte-identical to the leader's segment
  frames : Bytes
} derive(Debug, Eq, Show)

///|
pub fn encode_sync_response(response : SyncResponse) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_int64_be(response.base_offset)
  buf.write_leb128(response.record_count)
  buf.write_int64_be(response.high_watermark)
  buf.write_int64_be(response.log_end_offset)
  buf.write_leb128(response.frames.length())
  buf.write_bytes(response.frames[0:response.frames.length()])
  buf.to_bytes()
}

///|
pub fn decode_sync_response(payload : Bytes) -> Result[SyncResponse, String] {
  let reader = @codec.Reader::new(payload)
  let base_offset = match reader.read_i64_be() {
    Ok(v) => v
    Err(_) => return Err("truncated base offset")
  }
  let record_count = match reader.read_uleb128_len() {
    Ok(v) => v
    Err(_) => return Err("truncated record count")
  }
  let high_watermark = match reader.read_i64_be() {
    Ok(v) => v
    Err(_) => return Err("truncated high watermark")
  }
  let log_end_offset = match reader.read_i64_be() {
    Ok(v) => v
    Err(_) => return Err("truncated log end offset")
  }
  let len = match reader.read_uleb128_len() {
    Ok(v) => v
    Err(_) => return Err("truncated frame length")
  }
  let frames = match reader.read_bytes(len) {
    Ok(v) => v
    Err(_) => return Err("truncated frames")
  }
  if !reader.is_empty() {
    return Err("trailing bytes after sync response")
  }
  Ok(SyncResponse::{
    base_offset,
    record_count,
    high_watermark,
    log_end_offset,
    frames,
  })
}

///|
/// A SYNC_ACK: how far the follower has durably stored. The sender
/// identifies itself by address because that is how the leader keys
/// its progress ledger — the node's own view of who its replicas are
/// comes from the control plane, and a report must be attributable to
/// one of them (`ProgressLedger::observe` refuses strangers).
pub(all) struct SyncAck {
  partition : PartitionRef
  from : String
  leo : Int64
} derive(Debug, Eq, Show)

///|
pub fn encode_sync_ack(ack : SyncAck) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, ack.partition.topic)
  buf.write_leb128(ack.partition.partition)
  write_field(buf, ack.from)
  buf.write_int64_be(ack.leo)
  buf.to_bytes()
}

///|
pub fn decode_sync_ack(payload : Bytes) -> Result[SyncAck, String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  let from = match read_field(reader) {
    Ok(from) => from
    Err(e) => return Err(e)
  }
  if from.length() == 0 {
    return Err("an ack must say who sent it")
  }
  let leo = match reader.read_i64_be() {
    Ok(leo) => leo
    Err(_) => return Err("truncated leo")
  }
  if leo < 0L {
    return Err("negative leo")
  }
  Ok(SyncAck::{ partition: PartitionRef::{ topic, partition }, from, leo })
}

///|
/// One entry of a data node's assignment list: which partition this
/// node holds, and the control plane's current view of it.
///
/// The list travels in the *heartbeat reply* (P7): placement is state
/// the control plane owns — a node must not invent it — and the reply
/// is the channel a node already polls, exactly like the nomination
/// travels in the leader reply (README 决策 20).
pub(all) struct AssignmentView {
  topic : String
  partition : Int
  leader : String
  replicas : Array[String]
  nominated : String
} derive(Debug, Eq, Show)

///|
pub fn encode_assignments(assignments : Array[AssignmentView]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(assignments.length())
  for a in assignments {
    write_field(buf, a.topic)
    buf.write_leb128(a.partition)
    write_field(buf, a.leader)
    buf.write_leb128(a.replicas.length())
    for replica in a.replicas {
      write_field(buf, replica)
    }
    write_field(buf, a.nominated)
  }
  buf.to_bytes()
}

///|
pub fn decode_assignments(
  payload : Bytes,
) -> Result[Array[AssignmentView], String] {
  if payload.length() == 0 {
    // an empty reply means "nothing assigned", which is what a
    // control plane with no placements says
    return Ok([])
  }
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated assignment count")
  }
  let out : Array[AssignmentView] = []
  for _ in 0..<count {
    let topic = match read_field(reader) {
      Ok(topic) => topic
      Err(e) => return Err(e)
    }
    let partition = match reader.read_uleb128_len() {
      Ok(partition) => partition
      Err(_) => return Err("truncated assignment partition")
    }
    let leader = match read_field(reader) {
      Ok(leader) => leader
      Err(e) => return Err(e)
    }
    let replica_count = match reader.read_uleb128_len() {
      Ok(count) => count
      Err(_) => return Err("truncated assignment replica count")
    }
    let replicas : Array[String] = []
    for _ in 0..<replica_count {
      match read_field(reader) {
        Ok(replica) => replicas.push(replica)
        Err(e) => return Err(e)
      }
    }
    let nominated = match read_field(reader) {
      Ok(nominated) => nominated
      Err(e) => return Err(e)
    }
    out.push(AssignmentView::{ topic, partition, leader, replicas, nominated })
  }
  Ok(out)
}

///|
/// The cluster's applied pipeline (P11). Distinct from
/// `CMD_APPLY_PIPELINE` (19) on purpose: that one deploys to **one**
/// broker, which is the single-process shape and stays that way; these
/// speak to the cluster, where the control plane is the authority for
/// what every data node should be running, and nodes pull.
pub const CMD_CLUSTER_PIPELINE_APPLY = 32

///|
/// Ask the control plane for the cluster's current pipeline: an empty
/// payload asks for the revision alone, a non-empty one fetches the
/// document. Two questions in one command because the heartbeat already
/// carries the revision — a node only fetches when it differs, and a
/// several-kilobyte document should not ride every heartbeat.
pub const CMD_CLUSTER_PIPELINE_FETCH = 33

///|
/// Fetch one function set by name (P11/T54). The control plane holds
/// the authoritative copy; a node that needs one pulls it and validates
/// it locally, so the publish-time check runs where the asset runs.
pub const CMD_FUNCTION_SET_FETCH = 34

///|
/// The cluster pipeline as it travels: a monotonic revision and, when
/// asked for, the document itself.
pub(all) struct ClusterPipeline {
  revision : Int64
  /// empty when the control plane has no pipeline applied yet
  spec_json : String
} derive(Debug, Eq, Show)

///|
pub fn encode_cluster_pipeline(pipeline : ClusterPipeline) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(pipeline.revision)
  write_field(buf, pipeline.spec_json)
  buf.to_bytes()
}

///|
pub fn decode_cluster_pipeline(
  payload : Bytes,
) -> Result[ClusterPipeline, String] {
  let reader = @codec.Reader::new(payload)
  let revision = match reader.read_uleb128() {
    Ok(revision) => revision.reinterpret_as_int64()
    Err(_) => return Err("truncated pipeline revision")
  }
  let spec_json = match read_field(reader) {
    Ok(spec_json) => spec_json
    Err(e) => return Err(e)
  }
  Ok(ClusterPipeline::{ revision, spec_json })
}

///|
/// How far consumers have committed on one partition, as the control
/// plane tells the node that holds it (P9/T50). The holder needs this
/// to answer one question honestly: what may retention delete? The
/// committed prefix bounds it from one side, the slowest consumer from
/// the other, and only the coordinator knows the second.
pub(all) struct GroupFloor {
  topic : String
  partition : Int
  /// the oldest offset any group still needs. Deliberately *not*
  /// "absent means zero": absence means no group is consuming this
  /// partition, which is a different fact from "a group is at zero".
  floor : Int64
} derive(Debug, Eq, Show)

///|
/// The assignments payload with the consumer floors appended as an
/// optional section — the same additive shape the node record uses, so
/// a reader that predates floors reads the assignments and ignores the
/// tail.
pub fn encode_assignments_full(
  assignments : Array[AssignmentView],
  floors : Array[GroupFloor],
  pipeline_revision : Int64,
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  let head = encode_assignments(assignments)
  buf.write_bytes(head[0:head.length()])
  buf.write_leb128(floors.length())
  for floor in floors {
    write_field(buf, floor.topic)
    buf.write_leb128(floor.partition)
    buf.write_leb128(floor.floor)
  }
  // the cluster's pipeline revision (P11): the node compares it with
  // what it runs and pulls the document only when it differs
  buf.write_leb128(pipeline_revision)
  buf.to_bytes()
}

///|
/// Decodes assignments and, when present, the floors that follow them.
pub fn decode_assignments_full(
  payload : Bytes,
) -> Result[(Array[AssignmentView], Array[GroupFloor], Int64), String] {
  let assignments = match decode_assignments(payload) {
    Ok(assignments) => assignments
    Err(e) => return Err(e)
  }
  let floors : Array[GroupFloor] = []
  if payload.length() == 0 {
    return Ok((assignments, floors, 0L))
  }
  // walk the same bytes the assignments decoder walked, then read on
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated assignment count")
  }
  for _i = 0; _i < count; _i = _i + 1 {
    let _ = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _ = match reader.read_uleb128_len() {
      Ok(v) => v
      Err(_) => return Err("truncated assignment partition")
    }
    let _ = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let replicas = match reader.read_uleb128_len() {
      Ok(count) => count
      Err(_) => return Err("truncated assignment replica count")
    }
    for _j = 0; _j < replicas; _j = _j + 1 {
      let _ = match read_field(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    let _ = match read_field(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  // the optional tails: absent when the peer predates them
  match reader.read_uleb128_len() {
    Err(_) => Ok((assignments, floors, 0L))
    Ok(floor_count) => {
      for _i = 0; _i < floor_count; _i = _i + 1 {
        let topic = match read_field(reader) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let partition = match reader.read_uleb128_len() {
          Ok(v) => v
          Err(_) => return Err("truncated floor partition")
        }
        let floor = match reader.read_uleb128() {
          Ok(v) => v.reinterpret_as_int64()
          Err(_) => return Err("truncated floor offset")
        }
        floors.push(GroupFloor::{ topic, partition, floor })
      }
      // and the pipeline revision after them, if this peer sends one
      let revision = match reader.read_uleb128() {
        Ok(revision) => revision.reinterpret_as_int64()
        Err(_) => 0L
      }
      Ok((assignments, floors, revision))
    }
  }
}

///|
/// One partition's progress as a node reports it: enough for the
/// control plane to weigh candidates per partition instead of trusting
/// one node-level number (P7).
pub(all) struct PartitionReport {
  topic : String
  partition : Int
  leo : Int64
} derive(Debug, Eq, Show)

///|
/// The node report with its per-partition section. The section is
/// **appended** and optional: `decode_node` (no section expected) has
/// never checked that the reader was drained, so an older decoder
/// reads the record and ignores the tail, and this decoder treats a
/// missing tail as "no reports" — the extension is compatible in both
/// directions, which is the bar for not bumping the frame version.
pub fn encode_node_full(
  record : NodeRecord,
  reports : Array[PartitionReport],
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, record.id)
  write_field(buf, role_name(record.role))
  write_field(buf, record.address)
  buf.write_leb128(record.leo)
  buf.write_leb128(reports.length())
  for report in reports {
    write_field(buf, report.topic)
    buf.write_leb128(report.partition)
    buf.write_leb128(report.leo)
  }
  buf.to_bytes()
}

///|
pub fn decode_node_full(
  payload : Bytes,
) -> Result[(NodeRecord, Array[PartitionReport]), String] {
  let reader = @codec.Reader::new(payload)
  let id = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if id.length() == 0 || id.length() > 128 {
    return Err("node id must be 1..128 chars")
  }
  let role = match read_field(reader) {
    Ok(v) =>
      match parse_node_role(v) {
        Ok(role) => role
        Err(e) => return Err(e)
      }
    Err(e) => return Err(e)
  }
  let address = match read_field(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if address.length() == 0 {
    return Err("node address must not be empty")
  }
  let leo = match reader.read_uleb128() {
    Ok(leo) => leo.reinterpret_as_int64()
    Err(_) => return Err("truncated leo field")
  }
  let reports : Array[PartitionReport] = []
  // optional tail: absent when the peer predates per-partition reports
  match reader.read_uleb128_len() {
    Err(_) => ()
    Ok(count) =>
      for _ in 0..<count {
        let topic = match read_field(reader) {
          Ok(topic) => topic
          Err(e) => return Err(e)
        }
        let partition = match reader.read_uleb128_len() {
          Ok(partition) => partition
          Err(_) => return Err("truncated partition report")
        }
        let leo = match reader.read_uleb128() {
          Ok(leo) => leo.reinterpret_as_int64()
          Err(_) => return Err("truncated partition report leo")
        }
        reports.push(PartitionReport::{ topic, partition, leo })
      }
  }
  Ok((NodeRecord::{ id, role, address, leo }, reports))
}

///|
/// A CMD_LEADER request: which partition the caller is asking about.
pub fn encode_partition_ref(ref : PartitionRef) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, ref.topic)
  buf.write_leb128(ref.partition)
  buf.to_bytes()
}

///|
pub fn decode_partition_ref(payload : Bytes) -> Result[PartitionRef, String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  Ok(PartitionRef::{ topic, partition })
}

///|
/// The CMD_LEADER answer: who leads a partition and who else holds
/// it. An empty leader means the control plane has no assignment —
/// a legitimate answer, not an error: a partition without a live
/// leader is a state the caller waits out rather than a fault to
/// retry. The replica list is what lets the leader build its
/// progress ledger without inventing members.
pub(all) struct PartitionView {
  leader : String
  /// addresses of every replica, leader included when assigned
  replicas : Array[String]
  /// the replica the control plane is offering this partition to, or
  /// "" when no election is pending. A node that finds itself here
  /// promotes itself and confirms.
  nominated : String
} derive(Debug, Eq, Show)

///|
pub fn encode_partition_view(view : PartitionView) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, view.leader)
  buf.write_leb128(view.replicas.length())
  for replica in view.replicas {
    write_field(buf, replica)
  }
  write_field(buf, view.nominated)
  buf.to_bytes()
}

///|
pub fn decode_partition_view(payload : Bytes) -> Result[PartitionView, String] {
  let reader = @codec.Reader::new(payload)
  let leader = match read_field(reader) {
    Ok(leader) => leader
    Err(e) => return Err(e)
  }
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated replica count")
  }
  let replicas : Array[String] = []
  for _ in 0..<count {
    match read_field(reader) {
      Ok(replica) => replicas.push(replica)
      Err(e) => return Err(e)
    }
  }
  let nominated = match read_field(reader) {
    Ok(nominated) => nominated
    Err(e) => return Err(e)
  }
  if !reader.is_empty() {
    return Err("trailing bytes after partition view")
  }
  Ok(PartitionView::{ leader, replicas, nominated })
}

///|
/// The CMD_OFFSET_INFO answer: a partition's watermarks.
pub fn encode_offset_info(
  high_watermark : Int64,
  log_end_offset : Int64,
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_int64_be(high_watermark)
  buf.write_int64_be(log_end_offset)
  buf.to_bytes()
}

///|
pub fn decode_offset_info(payload : Bytes) -> Result[(Int64, Int64), String] {
  let reader = @codec.Reader::new(payload)
  let hw = match reader.read_i64_be() {
    Ok(hw) => hw
    Err(_) => return Err("truncated high watermark")
  }
  let leo = match reader.read_i64_be() {
    Ok(leo) => leo
    Err(_) => return Err("truncated log end offset")
  }
  Ok((hw, leo))
}

///|
/// A confirmation: which partition, and who took it. The control
/// plane accepts it only from the node it offered the partition to,
/// so a confirmation cannot create leadership — only report the one
/// it authorized.
pub(all) struct Confirmation {
  partition : PartitionRef
  candidate : String
} derive(Debug, Eq, Show)

///|
pub fn encode_confirmation(confirmation : Confirmation) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, confirmation.partition.topic)
  buf.write_leb128(confirmation.partition.partition)
  write_field(buf, confirmation.candidate)
  buf.to_bytes()
}

///|
pub fn decode_confirmation(payload : Bytes) -> Result[Confirmation, String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  let candidate = match read_field(reader) {
    Ok(candidate) => candidate
    Err(e) => return Err(e)
  }
  if candidate.length() == 0 {
    return Err("a confirmation needs a candidate")
  }
  if !reader.is_empty() {
    return Err("trailing bytes after confirmation")
  }
  Ok(Confirmation::{ partition: PartitionRef::{ topic, partition }, candidate })
}

///|
/// A topic declaration as it travels: the same fields as the metadata
/// store's, encoded with the protocol's conventions.
pub(all) struct WireTopic {
  name : String
  partitions : Int
  replication_factor : Int
} derive(Debug, Eq, Show)

///|
pub fn encode_wire_topic(topic : WireTopic) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, topic.name)
  buf.write_leb128(topic.partitions)
  buf.write_leb128(topic.replication_factor)
  buf.to_bytes()
}

///|
pub fn decode_wire_topic(payload : Bytes) -> Result[WireTopic, String] {
  let reader = @codec.Reader::new(payload)
  let name = match read_field(reader) {
    Ok(name) => name
    Err(e) => return Err(e)
  }
  let partitions = match reader.read_uleb128_len() {
    Ok(partitions) => partitions
    Err(_) => return Err("truncated partition count")
  }
  let replication_factor = match reader.read_uleb128_len() {
    Ok(rf) => rf
    Err(_) => return Err("truncated replication factor")
  }
  if !reader.is_empty() {
    return Err("trailing bytes after topic declaration")
  }
  Ok(WireTopic::{ name, partitions, replication_factor })
}

///|
/// The topic list reply: uleb128 count, then one declaration each.
pub fn encode_wire_topics(topics : Array[WireTopic]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(topics.length())
  for topic in topics {
    let bytes = encode_wire_topic(topic)
    buf.write_leb128(bytes.length())
    buf.write_bytes(bytes[0:bytes.length()])
  }
  buf.to_bytes()
}

///|
pub fn decode_wire_topics(payload : Bytes) -> Result[Array[WireTopic], String] {
  let reader = @codec.Reader::new(payload)
  let count = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return Err("truncated topic list")
  }
  let out : Array[WireTopic] = []
  for _ in 0..<count {
    let len = match reader.read_uleb128_len() {
      Ok(len) => len
      Err(_) => return Err("truncated topic list entry")
    }
    let bytes = match reader.read_bytes(len) {
      Ok(bytes) => bytes
      Err(_) => return Err("truncated topic list entry")
    }
    match decode_wire_topic(bytes) {
      Ok(topic) => out.push(topic)
      Err(e) => return Err("bad topic declaration: \{e}")
    }
  }
  Ok(out)
}

///|
/// A partitioned produce: topic + partition + one batch frame.
pub fn encode_partitioned_produce(
  topic : String,
  partition : Int,
  batch : Bytes,
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, topic)
  buf.write_leb128(partition)
  buf.write_bytes(batch[0:batch.length()])
  buf.to_bytes()
}

///|
/// Decodes the partitioned produce request (topic, partition, frame).
pub fn decode_partitioned_produce(
  payload : Bytes,
) -> Result[(String, Int, Bytes), String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  if !@spec.valid_topic_name(topic) {
    return Err("invalid topic name '\{topic}'")
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  if partition < 0 {
    return Err("negative partition index")
  }
  let frame = match reader.read_bytes(reader.remaining()) {
    Ok(frame) => frame
    Err(_) => return Err("truncated batch frame")
  }
  Ok((topic, partition, frame))
}

///|
/// A partitioned fetch: topic + partition + from + max.
pub fn encode_partitioned_fetch(
  topic : String,
  partition : Int,
  from : Int64,
  max : Int,
) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, topic)
  buf.write_leb128(partition)
  buf.write_int64_be(from)
  buf.write_uint_be(max.reinterpret_as_uint())
  buf.to_bytes()
}

///|
pub fn decode_partitioned_fetch(
  payload : Bytes,
) -> Result[(String, Int, Int64, Int), String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_field(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  if !@spec.valid_topic_name(topic) {
    return Err("invalid topic name '\{topic}'")
  }
  let partition = match reader.read_uleb128_len() {
    Ok(partition) => partition
    Err(_) => return Err("truncated partition index")
  }
  let from = match reader.read_i64_be() {
    Ok(from) => from
    Err(_) => return Err("truncated offset")
  }
  // max is u32 BE, matching the unpartitioned FETCH payload exactly
  let max = match reader.read_u32_be() {
    Ok(max) => max.reinterpret_as_int()
    Err(_) => return Err("truncated record count")
  }
  if from < 0L || max <= 0 {
    return Err("negative offset or non-positive record count")
  }
  Ok((topic, partition, from, max))
}

///|
/// Decodes an optional partition reference: an empty payload means
/// "partition 0" (the pre-P5 clients' shape, which must keep working),
/// anything else is `encode_partition_ref`'s output.
pub fn decode_partition_ref_opt(
  payload : Bytes,
) -> Result[PartitionRef, String] {
  if payload.length() == 0 {
    return Ok(PartitionRef::{ topic: "", partition: 0 })
  }
  decode_partition_ref(payload)
}
