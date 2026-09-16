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
  let buf = @buffer.Buffer::Buffer()
  write_field(buf, record.id)
  write_field(buf, role_name(record.role))
  write_field(buf, record.address)
  buf.write_leb128(record.leo)
  buf.to_bytes()
}

///|
/// Decodes a node record; any malformed input is a structured error,
/// never a partially-filled record.
pub fn decode_node(payload : Bytes) -> Result[NodeRecord, String] {
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
  Ok(NodeRecord::{ id, role, address, leo })
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
