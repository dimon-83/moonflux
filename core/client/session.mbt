// SPDX-License-Identifier: Apache-2.0
// Producer / Consumer: request framing, request-id echo enforcement,
// and the typed command calls. Transport-agnostic.

///|
/// A connected producer session.
pub struct Producer {
  conn : Conn
  mut next_rid : Int
  session : (Int, Int)
}

///|
/// A connected consumer session.
pub struct Consumer {
  conn : Conn
  mut next_rid : Int
  session : (Int, Int)
}

///|
/// Raises a client-side protocol failure.
pub(all) suberror ClientError {
  /// Transport failure (connect/send/recv/close).
  Transport(String)
  /// The server rejected the handshake or a command: stable code +
  /// message as sent by the server.
  Server(Int, String)
  /// The reply frame did not match the request (id or command kind).
  Protocol(String)
} derive(Debug, Eq)

///|
pub impl Show for ClientError with fn output(self, logger) {
  match self {
    Transport(msg) => logger.write_string("Transport(\{msg})")
    Server(code, msg) => logger.write_string("Server(code=\{code}, \{msg})")
    Protocol(msg) => logger.write_string("Protocol(\{msg})")
  }
}

///|
/// Performs the HELLO/WELCOME handshake on a fresh connection.
fn handshake(conn : Conn) -> Result[(Int, Int), ClientError] {
  match
    conn.send_frame(Frame::{
      cmd: CMD_HELLO,
      rid: 0,
      payload: encode_hello(1, 0),
    }) {
    Ok(_) => ()
    Err(e) => return Err(Transport(e))
  }
  let reply = match conn.recv_frame() {
    Ok(Some(reply)) => reply
    Ok(None) => return Err(Transport("server closed during handshake"))
    Err(e) => return Err(Transport(e))
  }
  match reply.cmd {
    CMD_WELCOME =>
      match decode_hello(reply.payload) {
        Ok((major, minor)) => Ok((major, minor))
        Err(e) => Err(Protocol(e))
      }
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("expected WELCOME, got cmd \{reply.cmd}"))
  }
}

///|
/// Sends one request and validates the echoed request id.
fn request(
  conn : Conn,
  rid : Int,
  cmd : Int,
  payload : Bytes,
) -> Result[Frame, ClientError] {
  match conn.send_frame(Frame::{ cmd, rid, payload }) {
    Ok(_) => ()
    Err(e) => return Err(Transport(e))
  }
  let reply = match conn.recv_frame() {
    Ok(Some(reply)) => reply
    Ok(None) => return Err(Transport("server closed mid-request"))
    Err(e) => return Err(Transport(e))
  }
  if reply.rid != rid {
    return Err(Protocol("reply request id \{reply.rid} does not match \{rid}"))
  }
  Ok(reply)
}

///|
/// Wraps an already-connected pipe (tests, loopback).
pub fn Producer::from_conn(conn : Conn) -> Result[Producer, ClientError] {
  let session = match handshake(conn) {
    Ok(session) => session
    Err(e) => return Err(e)
  }
  Ok(Producer::{ conn, next_rid: 1, session })
}

///|
/// The server's advertised protocol version.
pub fn Producer::session_version(self : Producer) -> (Int, Int) {
  self.session
}

///|
/// Sends a batch; returns (base_offset, record_count).
pub fn Producer::send(
  self : Producer,
  topic : String,
  records : Array[@protocol.Record],
) -> Result[(Int64, Int), ClientError] {
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  let batch = @protocol.encode_frame(-1L, records)
  payload.write_bytes(batch[0:batch.length()])
  let rid = self.next_rid
  self.next_rid += 1
  let reply = match request(self.conn, rid, CMD_PRODUCE, payload.to_bytes()) {
    Ok(reply) => reply
    Err(e) => return Err(e)
  }
  match reply.cmd {
    CMD_OK => {
      let reader = @codec.Reader::new(reply.payload)
      let base = match reader.read_i64_be() {
        Ok(base) => base
        Err(_) => return Err(Protocol("bad produce reply"))
      }
      let count = match reader.read_u32_be() {
        Ok(count) => count.reinterpret_as_int()
        Err(_) => return Err(Protocol("bad produce reply"))
      }
      Ok((base, count))
    }
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("unexpected reply cmd \{reply.cmd}"))
  }
}

///|
/// Closes the session.
pub fn Producer::close(self : Producer) -> Unit {
  (self.conn.close)()
}

///|

///|
/// Wraps an already-connected pipe (tests, loopback).
pub fn Consumer::from_conn(conn : Conn) -> Result[Consumer, ClientError] {
  let session = match handshake(conn) {
    Ok(session) => session
    Err(e) => return Err(e)
  }
  Ok(Consumer::{ conn, next_rid: 1, session })
}

///|
/// The server's advertised protocol version.
pub fn Consumer::session_version(self : Consumer) -> (Int, Int) {
  self.session
}

///|
/// Fetches up to `max` entries from `from`; entries carry offsets.
pub fn Consumer::fetch(
  self : Consumer,
  topic : String,
  from : Int64,
  max : Int,
) -> Result[Array[@log.LogEntry], ClientError] {
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_int64_be(from)
  payload.write_uint_be(max.reinterpret_as_uint())
  let rid = self.next_rid
  self.next_rid += 1
  let reply = match request(self.conn, rid, CMD_FETCH, payload.to_bytes()) {
    Ok(reply) => reply
    Err(e) => return Err(e)
  }
  match reply.cmd {
    CMD_OK => decode_fetch_reply(reply.payload, from)
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("unexpected reply cmd \{reply.cmd}"))
  }
}

///|
/// A committed read: like `fetch`, but the server answers only up to
/// the partition's high watermark (the prefix every replica holds) and
/// reports the watermarks it used. A consumer that cares about
/// durability asks this way; one that wants everything the leader has
/// keeps using `fetch` (Uncommitted, the reference's default).
pub fn Consumer::fetch_committed(
  self : Consumer,
  topic : String,
  from : Int64,
  max : Int,
) -> Result[(Array[@log.LogEntry], Int64, Int64), ClientError] {
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_int64_be(from)
  payload.write_uint_be(max.reinterpret_as_uint())
  let rid = self.next_rid
  self.next_rid += 1
  let reply = match
    request(self.conn, rid, CMD_FETCH_COMMITTED, payload.to_bytes()) {
    Ok(reply) => reply
    Err(e) => return Err(e)
  }
  match reply.cmd {
    CMD_OK => {
      let response = match decode_sync_response(reply.payload) {
        Ok(response) => response
        Err(e) => return Err(Protocol("bad committed fetch reply: \{e}"))
      }
      let entries = match decode_frames(response.frames, response.base_offset) {
        Ok(entries) => entries
        Err(e) => return Err(e)
      }
      Ok((entries, response.high_watermark, response.log_end_offset))
    }
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("unexpected reply cmd \{reply.cmd}"))
  }
}

///|
/// Closes the session.
pub fn Consumer::close(self : Consumer) -> Unit {
  (self.conn.close)()
}

///|
/// Decodes a concatenation of batch frames into offset-carrying
/// entries (shared by the committed reply path).
fn decode_frames(
  frames : Bytes,
  base_offset : Int64,
) -> Result[Array[@log.LogEntry], ClientError] {
  let _ = base_offset
  let reader = @codec.Reader::new(frames)
  let entries : Array[@log.LogEntry] = []
  while reader.remaining() > 0 {
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        let mut offset = batch.base_offset
        for record in batch.records {
          entries.push(@log.LogEntry::{ offset, record })
          offset += 1L
        }
      }
      Err(e) => return Err(Protocol("bad replicated frame: \{e}"))
    }
  }
  Ok(entries)
}

///|
/// Fetch reply: u32 batch_count, then per batch: u32 frame_len +
/// wire-protocol batch frame. Offsets derive from each frame's base.
fn decode_fetch_reply(
  payload : Bytes,
  from : Int64,
) -> Result[Array[@log.LogEntry], ClientError] {
  let reader = @codec.Reader::new(payload)
  let batch_count = match reader.read_u32_be() {
    Ok(count) => count.reinterpret_as_int()
    Err(_) => return Err(Protocol("bad fetch reply"))
  }
  let entries : Array[@log.LogEntry] = []
  for _i in 0..<batch_count {
    let frame_len = match reader.read_u32_be() {
      Ok(len) => len.reinterpret_as_int()
      Err(_) => return Err(Protocol("bad fetch reply"))
    }
    let frame = match reader.read_bytes(frame_len) {
      Ok(frame) => frame
      Err(_) => return Err(Protocol("bad fetch reply"))
    }
    match @protocol.decode_frame_strict(frame) {
      Ok(batch) => {
        let mut offset = batch.base_offset
        for record in batch.records {
          entries.push(@log.LogEntry::{ offset, record })
          offset += 1L
        }
      }
      Err(e) => return Err(Protocol("bad batch in fetch reply: \{e}"))
    }
  }
  let _ = from
  Ok(entries)
}

///|
/// A partitioned fetch: reads one partition explicitly (partition 0 is
/// what the unpartitioned `fetch` means). The reply shape is the same.
pub fn Consumer::fetch_partition(
  self : Consumer,
  topic : String,
  partition : Int,
  from : Int64,
  max : Int,
) -> Result[Array[@log.LogEntry], ClientError] {
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_leb128(partition)
  payload.write_int64_be(from)
  payload.write_uint_be(max.reinterpret_as_uint())
  let rid = self.next_rid
  self.next_rid += 1
  let reply = match
    request(self.conn, rid, CMD_FETCH_PARTITION, payload.to_bytes()) {
    Ok(reply) => reply
    Err(e) => return Err(e)
  }
  match reply.cmd {
    CMD_OK => decode_fetch_reply(reply.payload, from)
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("unexpected reply cmd \{reply.cmd}"))
  }
}

///|
/// Sends a batch to an explicit partition. The reply is identical to
/// `send`; partition 0 is what `send` means.
pub fn Producer::send_partition(
  self : Producer,
  topic : String,
  partition : Int,
  records : Array[@protocol.Record],
) -> Result[(Int64, Int), ClientError] {
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_leb128(partition)
  let batch = @protocol.encode_frame(-1L, records)
  payload.write_bytes(batch[0:batch.length()])
  let rid = self.next_rid
  self.next_rid += 1
  let reply = match
    request(self.conn, rid, CMD_PRODUCE_PARTITION, payload.to_bytes()) {
    Ok(reply) => reply
    Err(e) => return Err(e)
  }
  match reply.cmd {
    CMD_OK => {
      let reader = @codec.Reader::new(reply.payload)
      let base = match reader.read_i64_be() {
        Ok(base) => base
        Err(_) => return Err(Protocol("bad produce reply"))
      }
      let count = match reader.read_u32_be() {
        Ok(count) => count.reinterpret_as_int()
        Err(_) => return Err(Protocol("bad produce reply"))
      }
      Ok((base, count))
    }
    CMD_ERR => {
      let (code, message) = decode_error(reply.payload)
      Err(Server(code, message))
    }
    _ => Err(Protocol("unexpected reply cmd \{reply.cmd}"))
  }
}
