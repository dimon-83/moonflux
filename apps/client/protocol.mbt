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
