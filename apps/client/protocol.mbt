// SPDX-License-Identifier: Apache-2.0
// apps/client: protocol v2 frames — shared by the SDK and `serve`.
//
// Frame layout (all integers big-endian):
//   0   3  magic "MFS"
//   3   1  version = 0x02
//   4   1  cmd
//   5   4  request_id (echoed by the reply; enables future multiplexing)
//   9   4  payload_len
//  13   N  payload
//
// Handshake: a session starts with HELLO{major,minor}; the server
// answers WELCOME (same major) or ERR(unsupported-version). Any other
// command before HELLO is ERR(sequence).
//
// Error payload: u16 code + utf8 message.

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
