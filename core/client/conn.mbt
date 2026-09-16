// SPDX-License-Identifier: Apache-2.0
// The transport contract. Anything that can move bytes both ways can
// be a client transport: native TCP, a WebSocket bridge in the
// browser, or an AF_UNIX socketpair in tests.

///|
/// A bidirectional byte pipe. `recv_exact` must return exactly `n`
/// bytes or an error (EOF mid-read is an error).
pub(all) struct Conn {
  send : (Bytes) -> Result[Unit, String]
  recv_exact : (Int) -> Result[Bytes, String]
  close : () -> Unit
}

///|
/// Outcome of reading the opening frame of a session (used by the
/// server so version mismatches get a structured ERR reply instead
/// of a silent close).
pub(all) enum FirstRead {
  Got(Frame)
  Eof
  WrongVersion(Int)
  Garbage(String)
}

///|
/// Reads the session's opening frame, sniffing the version first so
/// a v1-shaped peer is answered rather than dropped.
pub fn Conn::recv_first(self : Conn) -> FirstRead {
  let magic = match (self.recv_exact)(4) {
    Ok(magic) => magic
    Err(e) =>
      if e.contains("closed mid-read") {
        return Eof
      } else {
        return Garbage(e)
      }
  }
  if magic[0] != b'M' || magic[1] != b'F' || magic[2] != b'S' {
    return Garbage("bad frame magic")
  }
  let version = magic[3].to_int()
  if version != PROTOCOL_VERSION {
    return WrongVersion(version)
  }
  let rest = match (self.recv_exact)(9) {
    Ok(rest) => rest
    Err(e) => return Garbage(e)
  }
  let header = Buffer::Buffer()
  header.write_bytes(magic[0:4])
  header.write_bytes(rest[0:9])
  let (cmd, rid, len) = match decode_header(header.to_bytes()) {
    Ok(parts) => parts
    Err(e) => return Garbage(e)
  }
  let payload = match (self.recv_exact)(len) {
    Ok(payload) => payload
    Err(e) => return Garbage(e)
  }
  Got(Frame::{ cmd, rid, payload })
}

///|
/// Sends one frame.
pub fn Conn::send_frame(self : Conn, frame : Frame) -> Result[Unit, String] {
  (self.send)(encode_frame(frame))
}

///|
/// Receives one frame; `None` on a clean EOF at a frame boundary.
pub fn Conn::recv_frame(self : Conn) -> Result[Frame?, String] {
  let header = match (self.recv_exact)(13) {
    Ok(header) => header
    Err(e) =>
      if e.contains("closed mid-read") {
        return Ok(None) // peer closed between frames
      } else {
        return Err(e)
      }
  }
  let (cmd, rid, len) = match decode_header(header) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  let payload = match (self.recv_exact)(len) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  Ok(Some(Frame::{ cmd, rid, payload }))
}

///|
/// One direction of an in-process duplex pair: bytes written by one
/// side wait here until the other reads them.
priv struct DuplexCell {
  mut pending : Bytes
}

///|
/// A connected pair of Conns that exchange bytes in memory, with no
/// sockets involved. The native adapter has a socketpair; this is its
/// backend-independent twin, which is what lets the client's own logic
/// be tested on every backend (including the browser target) rather
/// than only where sockets exist.
///
/// Semantics: writes land in the peer's buffer immediately, reads drain
/// it, and a read that would block is an error — the same contract the
/// socket transports have, minus the OS.
pub fn Conn::memory_pair() -> (Conn, Conn) {
  let a_inbox = DuplexCell::{ pending: b"" }
  let b_inbox = DuplexCell::{ pending: b"" }
  fn make(inbox : DuplexCell, outbox : DuplexCell) -> Conn {
    Conn::{
      send: fn(bytes) {
        let merged = @buffer.Buffer::Buffer()
        merged.write_bytes(outbox.pending[0:outbox.pending.length()])
        merged.write_bytes(bytes[0:bytes.length()])
        outbox.pending = merged.to_bytes()
        Ok(())
      },
      recv_exact: fn(n) {
        if n < 0 {
          return Err("negative read")
        }
        if inbox.pending.length() < n {
          return Err(
            "not enough bytes buffered (want \{n}, have \{inbox.pending.length()})",
          )
        }
        let head = inbox.pending[0:n].to_owned()
        inbox.pending = inbox.pending[n:inbox.pending.length()].to_owned()
        Ok(head)
      },
      close: fn() { () },
    }
  }
  (make(a_inbox, b_inbox), make(b_inbox, a_inbox))
}

///|
/// Serializes one session frame. Kept separate from `send_frame` so a
/// caller that owns its own write path (an event loop queueing replies)
/// can produce the same bytes without a connection.
pub fn encode_frame_bytes(frame : Frame) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MFS")
  out.write_byte(b'\x02')
  out.write_byte(frame.cmd.to_byte())
  out.write_uint_be(frame.rid.reinterpret_as_uint())
  out.write_uint_be(frame.payload.length().reinterpret_as_uint())
  out.write_bytes(frame.payload[0:frame.payload.length()])
  out.to_bytes()
}
