// SPDX-License-Identifier: Apache-2.0
// WebSocket transport (P4): the browser's way in.
//
// The protocol does not change here. A browser cannot open a TCP
// socket, so this module carries the *same* `MFS` frames inside
// WebSocket binary frames — the gateway is a transport, not a second
// API, and every command keeps its exact meaning (AGENTS §1 rule 2).
//
// SHA-1 and Base64 exist only because RFC 6455's handshake needs them
// (`Sec-WebSocket-Accept = base64(sha1(key + GUID))`); the kernel has
// no business with either, so they live in the native app layer with
// the rest of the transport. The RFC's own example is a test vector.

///|
/// SHA-1 (FIPS 180-1) over `data`. Implemented here rather than pulled
/// in: it is 60 lines, it is a handshake checksum (not a security
/// boundary — RFC 6455 says so explicitly), and the project does not
/// take third-party dependencies.
pub fn sha1(data : Bytes) -> Bytes {
  let mut h0 : UInt = 0x67452301U
  let mut h1 : UInt = 0xEFCDAB89U
  let mut h2 : UInt = 0x98BADCFEU
  let mut h3 : UInt = 0x10325476U
  let mut h4 : UInt = 0xC3D2E1F0U
  // message + 0x80 + zero padding + 64-bit big-endian bit length
  let msg_len = data.length()
  let padded_len = ((msg_len + 8) / 64 + 1) * 64
  let padded : FixedArray[Byte] = FixedArray::make(padded_len, b'\x00')
  for i in 0..<msg_len {
    padded[i] = data[i]
  }
  padded[msg_len] = b'\x80'
  let bit_len = msg_len.to_int64() * 8L
  for i in 0..<8 {
    let shift = (7 - i) * 8
    padded[padded_len - 8 + i] = ((bit_len >> shift) & 0xFFL).to_byte()
  }
  let w : FixedArray[UInt] = FixedArray::make(80, 0U)
  let mut block = 0
  while block < padded_len {
    for i in 0..<16 {
      let base = block + i * 4
      w[i] = (padded[base].to_uint() << 24) |
        (padded[base + 1].to_uint() << 16) |
        (padded[base + 2].to_uint() << 8) |
        padded[base + 3].to_uint()
    }
    for i in 16..<80 {
      let word = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
      w[i] = ((word << 1) | (word >> 31)) & 0xFFFFFFFFU
    }
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    for i in 0..<80 {
      let (f, k) = if i < 20 {
        ((b & c) | ((b ^ 0xFFFFFFFFU) & d), 0x5A827999U)
      } else if i < 40 {
        (b ^ c ^ d, 0x6ED9EBA1U)
      } else if i < 60 {
        ((b & c) | (b & d) | (c & d), 0x8F1BBCDCU)
      } else {
        (b ^ c ^ d, 0xCA62C1D6U)
      }
      let rotated = ((a << 5) | (a >> 27)) & 0xFFFFFFFFU
      let temp = (rotated + f + e + k + w[i]) & 0xFFFFFFFFU
      e = d
      d = c
      c = ((b << 30) | (b >> 2)) & 0xFFFFFFFFU
      b = a
      a = temp
    }
    h0 = (h0 + a) & 0xFFFFFFFFU
    h1 = (h1 + b) & 0xFFFFFFFFU
    h2 = (h2 + c) & 0xFFFFFFFFU
    h3 = (h3 + d) & 0xFFFFFFFFU
    h4 = (h4 + e) & 0xFFFFFFFFU
    block += 64
  }
  let out : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  let words = [h0, h1, h2, h3, h4]
  for i in 0..<5 {
    out[i * 4] = ((words[i] >> 24) & 0xFFU).to_byte()
    out[i * 4 + 1] = ((words[i] >> 16) & 0xFFU).to_byte()
    out[i * 4 + 2] = ((words[i] >> 8) & 0xFFU).to_byte()
    out[i * 4 + 3] = (words[i] & 0xFFU).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// Standard Base64 (RFC 4648) with padding.
pub fn base64_encode(data : Bytes) -> String {
  let sb = StringBuilder::new()
  let mut i = 0
  let n = data.length()
  while i < n {
    let b0 = data[i].to_uint()
    let b1 = if i + 1 < n { data[i + 1].to_uint() } else { 0U }
    let b2 = if i + 2 < n { data[i + 2].to_uint() } else { 0U }
    let triple = (b0 << 16) | (b1 << 8) | b2
    sb.write_char(base64_char(((triple >> 18) & 0x3FU).to_int()))
    sb.write_char(base64_char(((triple >> 12) & 0x3FU).to_int()))
    if i + 1 < n {
      sb.write_char(base64_char(((triple >> 6) & 0x3FU).to_int()))
    } else {
      sb.write_char('=')
    }
    if i + 2 < n {
      sb.write_char(base64_char((triple & 0x3FU).to_int()))
    } else {
      sb.write_char('=')
    }
    i += 3
  }
  sb.to_string()
}

///|
/// The Base64 alphabet by index, as a code point (the same technique
/// core/codec uses for hex digits).
fn base64_char(index : Int) -> Char {
  if index < 26 {
    (index + 65).unsafe_to_char() // 'A'..
  } else if index < 52 {
    (index - 26 + 97).unsafe_to_char() // 'a'..
  } else if index < 62 {
    (index - 52 + 48).unsafe_to_char() // '0'..
  } else if index == 62 {
    (43).unsafe_to_char() // '+'
  } else {
    (47).unsafe_to_char() // '/'
  }
}

///|
/// RFC 6455's magic GUID.
const WS_GUID : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
/// The `Sec-WebSocket-Accept` value for a client key.
pub fn ws_accept_key(client_key : String) -> String {
  let combined = client_key + WS_GUID
  let bytes = @utf8.encode(combined[0:combined.length()])
  base64_encode(sha1(bytes))
}

///|
/// True when the first bytes look like an HTTP request: a browser
/// arriving at the same port a CLI uses must be recognized, not fed to
/// the frame parser.
pub fn looks_like_http(head : Bytes) -> Bool {
  head.length() >= 4 &&
  head[0] == b'G' &&
  head[1] == b'E' &&
  head[2] == b'T' &&
  head[3] == b' '
}

///|
/// Reads an HTTP request head (up to the blank line) from a connection.
fn read_http_head(conn : @client.Conn) -> Result[String, String] {
  let mut head : Bytes = b""
  while true {
    let chunk = match (conn.recv_exact)(1) {
      Ok(chunk) => chunk
      Err(e) => return Err(e)
    }
    head = head + chunk
    if head.length() > 8192 {
      return Err("HTTP request head too large")
    }
    if head.length() >= 4 {
      let tail = head[head.length() - 4:head.length()]
      if tail[0] == b'\r' &&
        tail[1] == b'\n' &&
        tail[2] == b'\r' &&
        tail[3] == b'\n' {
        return Ok(@utf8.decode_lossy(head[0:head.length()]))
      }
    }
  }
  Err("unreachable")
}

///|
/// Extracts a header value from an HTTP request head (case-insensitive
/// name match, trimmed value).
fn http_header(head : String, name : String) -> String? {
  let want = name.to_lower()
  for line in head.split("\r\n") {
    let line = line.to_owned()
    match line.rev_split_once(":") {
      Some((key, value)) =>
        if key.to_lower() == want {
          return Some(value.trim().to_owned())
        }
      None => ()
    }
  }
  None
}

///|
/// Performs the server side of the RFC 6455 handshake. Returns the
/// client's key's answer on success; every failure is a structured
/// reason (the caller answers 400 rather than dropping silently).
pub fn ws_handshake(conn : @client.Conn) -> Result[Unit, String] {
  let head = match read_http_head(conn) {
    Ok(head) => head
    Err(e) => return Err(e)
  }
  let upgrade = match http_header(head, "Upgrade") {
    Some(value) => value.to_lower()
    None => return Err("not a websocket upgrade (no Upgrade header)")
  }
  if upgrade != "websocket" {
    return Err("Upgrade is '\{upgrade}', not websocket")
  }
  let key = match http_header(head, "Sec-WebSocket-Key") {
    Some(key) => key
    None => return Err("missing Sec-WebSocket-Key")
  }
  let response = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Accept: \{ws_accept_key(key)}\r\n\r\n"
  let bytes = @utf8.encode(response[0:response.length()])
  match (conn.send)(bytes) {
    Ok(_) => Ok(())
    Err(e) => Err("send handshake: \{e}")
  }
}

///|
/// One inbound WebSocket frame.
pub(all) struct WsFrame {
  opcode : Int
  payload : Bytes
} derive(Debug, Eq, Show)

///|
/// Opcodes this transport cares about.
pub const WS_CONTINUATION : Int = 0

///|
pub const WS_TEXT : Int = 1

///|
pub const WS_BINARY : Int = 2

///|
pub const WS_CLOSE : Int = 8

///|
pub const WS_PING : Int = 9

///|
pub const WS_PONG : Int = 10

///|
/// Reads one frame. Client frames MUST be masked (RFC 6455 §5.1) and
/// this refuses anything unmasked, because a server that accepts
/// unmasked input is a proxy-poisoning hole rather than a convenience.
pub fn ws_read_frame(conn : @client.Conn) -> Result[WsFrame, String] {
  let header = match (conn.recv_exact)(2) {
    Ok(header) => header
    Err(e) => return Err(e)
  }
  let opcode = (header[0] & 0x0F).to_int()
  let masked = (header[1] & 0x80) != b'\x00'
  let mut len : Int = (header[1] & 0x7F).to_int()
  if len == 126 {
    let ext = match (conn.recv_exact)(2) {
      Ok(ext) => ext
      Err(e) => return Err(e)
    }
    len = (ext[0].to_int() << 8) | ext[1].to_int()
  } else if len == 127 {
    let ext = match (conn.recv_exact)(8) {
      Ok(ext) => ext
      Err(e) => return Err(e)
    }
    // payloads this large are not a thing for control frames; the
    // upper 32 bits must be zero for anything we serve
    let mut big : Int64 = 0L
    for i in 0..<8 {
      big = (big << 8) | ext[i].to_int64()
    }
    if big > 67108864L {
      return Err("websocket frame larger than the 64MiB cap")
    }
    len = big.to_int()
  }
  if len < 0 || len > 67108864 {
    return Err("bad websocket frame length")
  }
  if !masked {
    return Err("client frames must be masked (RFC 6455 §5.1)")
  }
  let mask = match (conn.recv_exact)(4) {
    Ok(mask) => mask
    Err(e) => return Err(e)
  }
  let payload = if len > 0 {
    match (conn.recv_exact)(len) {
      Ok(payload) => payload
      Err(e) => return Err(e)
    }
  } else {
    b""
  }
  let unmasked : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    unmasked[i] = (payload[i].to_uint() ^ mask[i % 4].to_uint()).to_byte()
  }
  Ok(WsFrame::{ opcode, payload: Bytes::from_array(unmasked), })
}

///|
/// Encodes one unmasked frame (servers must not mask). Pure bytes, so
/// the event loop can queue a reply without holding a Conn.
pub fn ws_encode_frame(opcode : Int, payload : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_byte((0x80 | opcode).to_byte())
  let len = payload.length()
  if len < 126 {
    out.write_byte(len.to_byte())
  } else if len <= 65535 {
    out.write_byte(b'\x7E')
    out.write_byte(((len >> 8) & 0xFF).to_byte())
    out.write_byte((len & 0xFF).to_byte())
  } else {
    out.write_byte(b'\x7F')
    for i in 0..<8 {
      let shift = (7 - i) * 8
      out.write_byte(((len >> shift) & 0xFF).to_byte())
    }
  }
  out.write_bytes(payload[0:payload.length()])
  out.to_bytes()
}

///|
/// Writes one frame to a blocking connection.
pub fn ws_write_frame(
  conn : @client.Conn,
  opcode : Int,
  payload : Bytes,
) -> Result[Unit, String] {
  (conn.send)(ws_encode_frame(opcode, payload))
}

///|
/// Wraps a handshaken connection as a `Conn`: writes become binary
/// frames, reads are reassembled from frames. This is the whole
/// gateway — everything above it (the frame codec, the commands, the
/// handlers) is the same code the TCP path runs.
///
/// Fragmented messages (continuation frames) are reassembled; control
/// frames are answered here (ping → pong) or end the session (close).
pub fn ws_transport(conn : @client.Conn) -> @client.Conn {
  let pending : DuplexBuffer = DuplexBuffer::{ data: b"", }
  @client.Conn::{
    send: fn(bytes) { ws_write_frame(conn, WS_BINARY, bytes) },
    recv_exact: fn(n) {
      while pending.data.length() < n {
        let frame = match ws_read_frame(conn) {
          Ok(frame) => frame
          Err(e) => return Err(e)
        }
        match frame.opcode {
          WS_BINARY | WS_TEXT => pending.data = pending.data + frame.payload
          WS_CONTINUATION => pending.data = pending.data + frame.payload
          WS_PING =>
            match ws_write_frame(conn, WS_PONG, frame.payload) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
          WS_PONG => ()
          WS_CLOSE => {
            let _ = ws_write_frame(conn, WS_CLOSE, b"")
            return Err("websocket closed by peer")
          }
          other => return Err("unsupported websocket opcode \{other}")
        }
      }
      let head = pending.data[0:n].to_owned()
      pending.data = pending.data[n:pending.data.length()].to_owned()
      Ok(head)
    },
    close: fn() {
      let _ = ws_write_frame(conn, WS_CLOSE, b"")
      (conn.close)()
    },
  }
}

///|
/// Bytes waiting to be delivered to the layer above (a WebSocket
/// message may carry more than one request's worth).
priv struct DuplexBuffer {
  mut data : Bytes
}

///|
/// Wraps a transport so that `head` is delivered before whatever the
/// underlying connection holds. Used when a node sniffs the first bytes
/// to tell a browser from a CLI: the sniff consumes them, and they must
/// not be lost.
pub fn prefixed_transport(head : Bytes, rest : @client.Conn) -> @client.Conn {
  let pending = DuplexBuffer::{ data: head, }
  @client.Conn::{
    send: fn(bytes) { (rest.send)(bytes) },
    recv_exact: fn(n) {
      while pending.data.length() < n {
        let more = match (rest.recv_exact)(n - pending.data.length()) {
          Ok(more) => more
          Err(e) => return Err(e)
        }
        pending.data = pending.data + more
      }
      let out = pending.data[0:n].to_owned()
      pending.data = pending.data[n:pending.data.length()].to_owned()
      Ok(out)
    },
    close: fn() { (rest.close)() },
  }
}

///|
/// The HTTP answer a refused upgrade gets. A request that reached the
/// right port but was not a WebSocket handshake is a client mistake,
/// and saying so costs one line — silence costs an afternoon.
pub fn http_bad_request(reason : String) -> Bytes {
  let body = "not a websocket upgrade: " + reason + "\n"
  let response = "HTTP/1.1 400 Bad Request\r\n" +
    "Content-Type: text/plain\r\n" +
    "Content-Length: " +
    body.length().to_string() +
    "\r\n" +
    "Connection: close\r\n\r\n" +
    body
  @utf8.encode(response[0:response.length()])
}
