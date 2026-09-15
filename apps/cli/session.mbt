// SPDX-License-Identifier: Apache-2.0
// P0 session protocol (app-level framing on top of TCP): a thin
// command envelope so produce/consume can talk to `serve`. The
// record payloads are wire-protocol batch frames. P1 replaces this
// with the fully versioned multiplexed protocol.

///|
const CMD_PRODUCE = 1

///|
const CMD_FETCH = 2

///|
const CMD_OK = 3

///|
const CMD_ERR = 4

///|
const SESSION_PAYLOAD_LIMIT = 33554432

///|
fn encode_session_frame(cmd : Int, payload : Bytes) -> Bytes {
  let out = Buffer::Buffer()
  out.write_bytes(b"MFS"[0:3])
  out.write_byte(b'\x01')
  out.write_byte(cmd.to_byte())
  out.write_byte(b'\x00') // reserved
  out.write_uint_be(payload.length().reinterpret_as_uint())
  out.write_bytes(payload[0:payload.length()])
  out.to_bytes()
}

///|
/// Reads exactly `n` bytes; fewer at end-of-stream is an error.
fn recv_exact(stream : @net.TcpStream, n : Int) -> Result[Bytes, String] {
  if n < 0 || n > SESSION_PAYLOAD_LIMIT {
    return Err("session frame size out of bounds")
  }
  let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut filled = 0
  while filled < n {
    match stream.recv(buf, n - filled) {
      Ok(0) => return Err("connection closed mid-frame")
      Ok(k) => filled += k
      Err(e) => return Err("recv: \{e}")
    }
  }
  Ok(Bytes::from_fixedarray(buf, len=filled))
}

///|
/// Reads one session frame; `Ok(None)` on a clean EOF at the frame
/// boundary.
fn recv_session_frame(stream : @net.TcpStream) -> Result[(Int, Bytes)?, String] {
  let head = match recv_exact(stream, 10) {
    Ok(head) => head
    Err(_) => return Ok(None) // clean EOF before any header byte
  }
  if head[0] != b'M' || head[1] != b'F' || head[2] != b'S' {
    return Err("bad session magic")
  }
  let version = head[3].to_int()
  if version != 1 {
    return Err("unsupported session version \{version}")
  }
  let cmd = head[4].to_int()
  if head[5] != b'\x00' {
    return Err("bad session header")
  }
  let len0 = head[6].to_int()
  let len1 = head[7].to_int()
  let len2 = head[8].to_int()
  let len3 = head[9].to_int()
  let payload_len = (((((len0 << 8) | len1) << 8) | len2) << 8) | len3
  let payload = match recv_exact(stream, payload_len) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  Ok(Some((cmd, payload)))
}

///|
/// Sends one session frame.
fn send_session_frame(
  stream : @net.TcpStream,
  cmd : Int,
  payload : Bytes,
) -> Result[Unit, String] {
  if payload.length() > SESSION_PAYLOAD_LIMIT {
    return Err("payload too large")
  }
  match stream.send_all(encode_session_frame(cmd, payload)) {
    Ok(_) => Ok(())
    Err(e) => Err("send: \{e}")
  }
}

///|
/// Splits "host:port" (IPv4/name only for P0).
fn parse_listen_addr(addr : String) -> (String, Int) {
  match addr.rev_split_once(":") {
    Some((host, port)) =>
      match (try? @string.parse_int(port[0:port.length()])) {
        Ok(port) => (host.to_owned(), port)
        Err(_) => fail("bad port in --listen \{addr}")
      }
    None => fail("--listen expects host:port, got \{addr}")
  }
}
