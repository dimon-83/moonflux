// SPDX-License-Identifier: Apache-2.0
// apps/client: connection abstraction. The SDK never touches sockets
// directly — transports are injected as function fields, so tests run
// over a socketpair and production runs over TCP.

///|
/// A bidirectional byte pipe. `recv_exact` must return exactly `n`
/// bytes or an error (EOF mid-read is an error).
pub(all) struct Conn {
  send : (Bytes) -> Result[Unit, String]
  recv_exact : (Int) -> Result[Bytes, String]
  close : () -> Unit
}

///|
fn wrap_stream(stream : @net.TcpStream) -> Conn {
  Conn::{
    send: fn(bytes) {
      match stream.send_all(bytes) {
        Ok(_) => Ok(())
        Err(e) => Err("send: \{e}")
      }
    },
    recv_exact: fn(n) {
      if n < 0 || n > MAX_FRAME_PAYLOAD {
        return Err("recv size out of bounds")
      }
      let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
      let mut filled = 0
      while filled < n {
        match stream.recv(buf, n - filled) {
          Ok(0) => return Err("connection closed mid-read")
          Ok(k) => filled += k
          Err(e) => return Err("recv: \{e}")
        }
      }
      Ok(Bytes::from_fixedarray(buf, len=filled))
    },
    close: fn() { let _ = stream.close() },
  }
}

///|
/// Wraps an accepted server-side stream as a Conn.
pub fn Conn::from_stream(stream : @net.TcpStream) -> Conn {
  wrap_stream(stream)
}

///|
/// Opens a blocking TCP connection.
pub fn Conn::tcp(host : String, port : Int) -> Result[Conn, String] {
  match @net.TcpStream::connect(host, port) {
    Ok(stream) => Ok(wrap_stream(stream))
    Err(e) => Err("connect \{host}:\{port}: \{e}")
  }
}

///|
/// Opens a connection whose reads give up after `timeout_ms`.
///
/// Node-to-node calls need this. Both peers are single-threaded
/// loops that alternately serve requests and do housekeeping, so two
/// nodes can end up each waiting on the other — the control plane
/// nominating a replica while that replica is asking the control
/// plane who leads. A deadline converts that deadlock into a failed
/// call that the next tick simply retries, which is the only sane
/// outcome for a liveness protocol: no node should be able to hang
/// another by being busy.
pub fn Conn::tcp_with_timeout(
  host : String,
  port : Int,
  timeout_ms : Int,
) -> Result[Conn, String] {
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{host}:\{port}: \{e}")
  }
  match stream.set_recv_timeout_ms(timeout_ms) {
    Ok(_) => ()
    Err(e) => return Err("set timeout: \{e}")
  }
  Ok(wrap_stream(stream))
}

///|
/// Creates a connected in-process pair (AF_UNIX socketpair) for tests
/// and loopback tooling.
pub fn Conn::socketpair() -> Result[(Conn, Conn), String] {
  match @net.socketpair() {
    Ok((a, b)) => Ok((wrap_stream(a), wrap_stream(b)))
    Err(e) => Err("socketpair: \{e}")
  }
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
