// SPDX-License-Identifier: Apache-2.0
// The connection hub: one thread, many connections (P5).
//
// Before this, `serve` accepted a connection and serviced it until it
// closed. That is fine for a CLI that connects, asks, and leaves — and
// fatal for anything that stays: a browser's WebSocket held the single
// slot, and every other client looked like a hung cluster. P4's gate hit
// exactly that.
//
// The fix is not threads. Each node is a single-threaded loop that
// alternates between serving and housekeeping (AGENTS §1.2), and this
// keeps that shape: poll every connection, advance the ones that have
// bytes, and never wait on one while another has work.
//
// A connection is a small state machine, not a function call stack:
//   reading → (a whole frame arrived?) → dispatch → writing → reading
// Partial frames simply stay buffered until the rest arrives, which is
// what lets a slow client coexist with a fast one.

///|
/// How much a single connection may buffer before the hub gives up on
/// it. A client that does not read must not be able to eat the
/// process's memory, so the limit is a real one and exceeding it
/// disconnects that client — loudly.
const MAX_INBOX_BYTES : Int = 8 * 1024 * 1024

///|
/// The same bound for the write side: a peer that never reads while we
/// have data queued for it.
const MAX_OUTBOX_BYTES : Int = 8 * 1024 * 1024

///|
/// One served connection.
pub struct HubConnection {
  stream : @net.TcpStream
  /// bytes read from the socket, not yet consumed by the parser
  mut inbox : Bytes
  /// for WebSocket connections: payload bytes unwrapped from WS frames,
  /// waiting for the frame parser. A WS frame is *envelope*, the bytes
  /// inside it are the session's frames — conflating the two makes every
  /// command look like it has cmd 0 (which is what the first cut did).
  mut decoded : Bytes
  /// replies queued for this peer, not yet written
  mut outbox : Bytes
  /// the session state: what this connection speaks and where it is
  mut phase : Phase
  /// a label for logs: "tcp" or "websocket"
  mut kind : String
}

///|
pub(all) enum Phase {
  /// Waiting for the handshake (HELLO as a frame, or an HTTP upgrade).
  Handshake
  /// Handshake done; frames are serviced as they complete.
  Frames
  /// The peer went away; the hub drops it on the next pass.
  Closed
} derive(Debug, Eq)

///|
/// What the hub needs to know about one request to answer it. The
/// handlers are the same functions the single-connection path uses — the
/// hub only decides *when* they run.
pub(all) struct HubHandler {
  /// Handles one complete frame, returning the reply frame to send.
  on_frame : (@client.Frame) -> @client.Frame
  /// Called once the handshake completes (after WELCOME is queued).
  on_ready : () -> Unit
}

///|
/// The hub: an accept backlog plus every connection currently open.
pub struct ConnectionHub {
  listener : @net.TcpListener
  mut conns : Array[HubConnection]
  /// the longest frame header + the largest payload this server accepts
  max_frame : Int
  poll_timeout_ms : Int
}

///|
pub fn ConnectionHub::new(
  listener : @net.TcpListener,
  poll_timeout_ms : Int,
) -> ConnectionHub {
  ConnectionHub::{
    listener,
    conns: [],
    max_frame: @client.MAX_FRAME_PAYLOAD + 13,
    poll_timeout_ms,
  }
}

///|
/// Registers an accepted stream as a connection (non-blocking from its
/// first byte: the hub never blocks on one peer).
fn ConnectionHub::adopt(self : ConnectionHub, stream : @net.TcpStream) -> Unit {
  match stream.set_nonblocking(true) {
    Ok(_) => ()
    Err(e) => {
      note("dropping a connection: cannot go non-blocking (\{e})")
      return
    }
  }
  self.conns.push(HubConnection::{
    stream,
    inbox: b"",
    decoded: b"",
    outbox: b"",
    phase: Handshake,
    kind: "tcp",
  })
}

///|
/// One pass: accept whatever is pending, read what is readable, answer
/// what is complete, write what is queued, and forget what closed.
///
/// Returns the number of live connections, so a caller can log churn
/// without asking again.
pub fn ConnectionHub::poll_once(
  self : ConnectionHub,
  handler : HubHandler,
  on_new_connection : (String) -> Unit,
) -> Int {
  // 1. accept everything that is waiting: a backlog must not sit until
  //    the next tick just because one connection is busy
  while true {
    match self.listener.accept() {
      Ok(stream) => {
        self.adopt(stream)
        let kind = if self.conns.length() > 0 {
          self.conns[self.conns.length() - 1].kind
        } else {
          "tcp"
        }
        on_new_connection(kind)
      }
      Err(TimedOut) => break
      Err(WouldBlock) => break
      Err(e) => {
        // a listener error is worth reporting, but not worth dying for
        note("accept: \{e}")
        break
      }
    }
  }
  if self.conns.length() == 0 {
    // nothing to serve: sleep out the tick so the caller's housekeeping
    // (heartbeats, reconcile) still happens on schedule
    let _ = @net.poll_readable([], self.poll_timeout_ms)
    return 0
  }
  // 2. find out which connections have something
  let streams : Array[@net.TcpStream] = []
  for conn in self.conns {
    streams.push(conn.stream)
  }
  let ready = match @net.poll_readable(streams, self.poll_timeout_ms) {
    Ok(ready) => ready
    Err(e) => {
      note("poll: \{e}")
      return self.conns.length()
    }
  }
  // 3. read them, then service whichever connections now hold one or
  //    more complete frames
  for index in ready {
    let conn = self.conns[index]
    match read_available(conn) {
      Ok(_) => ()
      Err(e) =>
        if !(conn.phase is Closed) {
          note("connection (\{conn.kind}) closed: \{e}")
          conn.phase = Closed
        }
    }
  }
  for i in 0..<self.conns.length() {
    if self.conns[i].phase is Closed {
      continue
    }
    service(self.conns[i], handler)
  }
  // 4. write replies and drop the dead
  let alive : Array[HubConnection] = []
  for conn in self.conns {
    if conn.phase is Closed {
      // best effort, and deliberately before the close: a refusal or a
      // closing handshake is written here rather than vanishing
      let _ = flush(conn)
      let _ = conn.stream.close()
      continue
    }
    match flush(conn) {
      Ok(_) => alive.push(conn)
      Err(e) => {
        note("connection (\{conn.kind}) dropped while writing: \{e}")
        let _ = conn.stream.close()
      }
    }
  }
  self.conns = alive
  self.conns.length()
}

///|
/// Reads everything currently available into the connection's inbox.
/// A zero-byte read is a clean close; WouldBlock means "nothing yet",
/// which is not an error and must not be logged as one.
fn read_available(conn : HubConnection) -> Result[Unit, String] {
  let buf : FixedArray[Byte] = FixedArray::make(8192, b'\x00')
  while true {
    match conn.stream.recv_some(buf, buf.length()) {
      Ok(0) => {
        conn.phase = Closed
        return Ok(())
      }
      Ok(n) => {
        conn.inbox = append(conn.inbox, Bytes::from_array(buf[0:n]))
        if conn.inbox.length() > MAX_INBOX_BYTES {
          return Err(
            "peer sent \{conn.inbox.length()} bytes without a complete request",
          )
        }
      }
      Err(WouldBlock) => return Ok(())
      Err(e) => return Err("\{e}")
    }
  }
  Ok(())
}

///|
/// Drives the connection's protocol state machine over whatever is
/// buffered. HTTP upgrades and frame sessions both live here, so a
/// browser and a CLI are served by the same code path from the same
/// loop.
fn service(conn : HubConnection, handler : HubHandler) -> Unit {
  match conn.phase {
    Handshake => {
      if conn.inbox.length() >= 4 && looks_like_http(conn.inbox[0:4].to_owned()) {
        // a browser: finish the HTTP upgrade if it is complete
        match try_upgrade(conn) {
          Ok(true) => {
            conn.kind = "websocket"
            (handler.on_ready)()
          }
          Ok(false) => () // the request head is still arriving
          Err(e) => {
            // an HTTP client deserves an HTTP answer: silence from the
            // right port reads as "the server is broken"
            note("upgrade refused: \{e}")
            queue(conn, http_bad_request(e))
            conn.phase = Closed
          }
        }
        return
      }
      // either transport: wait for the full HELLO frame (over
      // WebSocket the frames live inside WS envelopes, so unwrap first)
      if conn.kind == "websocket" {
        match drain_ws_frames(conn) {
          Ok(_) => ()
          Err(e) => {
            note("websocket frame error: \{e}")
            conn.phase = Closed
            return
          }
        }
      }
      match next_frame(conn) {
        Ok(None) => ()
        Ok(Some(frame)) => {
          let reply = (handler.on_frame)(frame)
          queue(conn, @client.encode_frame_bytes(reply))
          if reply.cmd == @client.CMD_ERR {
            // a refused handshake ends the session, as it does on the
            // single-connection path
            conn.phase = Closed
            return
          }
          conn.phase = Frames
          (handler.on_ready)()
        }
        Err(e) => {
          note("handshake failed: \{e}")
          conn.phase = Closed
        }
      }
    }
    Frames => {
      if conn.kind == "websocket" {
        match drain_ws_frames(conn) {
          Ok(_) => ()
          Err(e) => {
            note("websocket frame error: \{e}")
            conn.phase = Closed
            return
          }
        }
        if conn.phase is Closed {
          return
        }
      }
      while true {
        let frame = match next_frame(conn) {
          Ok(None) => return
          Ok(Some(frame)) => frame
          Err(e) => {
            note("frame error: \{e}")
            conn.phase = Closed
            return
          }
        }
        let reply = (handler.on_frame)(frame)
        queue(conn, @client.encode_frame_bytes(reply))
      }
    }
    Closed => ()
  }
}

///|
/// Pulls one complete session frame out of the inbox, leaving a partial
/// frame in place for the next pass.
fn next_frame(conn : HubConnection) -> Result[@client.Frame?, String] {
  let source = conn.source()
  if source.length() < 13 {
    return Ok(None)
  }
  let head = source[0:13]
  if head[0] != b'M' || head[1] != b'F' || head[2] != b'S' {
    return Err("not an MFS frame")
  }
  let payload_len = ((head[9].to_uint() << 24) |
  (head[10].to_uint() << 16) |
  (head[11].to_uint() << 8) |
  head[12].to_uint()).to_int()
  if payload_len < 0 || payload_len > @client.MAX_FRAME_PAYLOAD {
    return Err("frame payload of \{payload_len} bytes is out of range")
  }
  if source.length() < 13 + payload_len {
    return Ok(None) // the rest is still on its way
  }
  let cmd = head[4].to_int()
  let rid = ((head[5].to_uint() << 24) |
  (head[6].to_uint() << 16) |
  (head[7].to_uint() << 8) |
  head[8].to_uint()).to_int()
  let payload = source[13:13 + payload_len].to_owned()
  conn.consume(13 + payload_len)
  Ok(Some(@client.Frame::{ cmd, rid, payload }))
}

///|
/// Completes the WebSocket handshake if the HTTP head has arrived.
/// Returns false while it is still arriving.
fn try_upgrade(conn : HubConnection) -> Result[Bool, String] {
  let text = @utf8.decode_lossy(conn.inbox[0:conn.inbox.length()])
  let head_end = match text.find("\r\n\r\n") {
    Some(index) => index
    None => {
      if conn.inbox.length() > 8192 {
        return Err("HTTP request head too large")
      }
      return Ok(false)
    }
  }
  let head = text[0:head_end + 4].to_owned()
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
  queue(conn, @utf8.encode(response[0:response.length()]))
  conn.inbox = conn.inbox[head_end + 4:conn.inbox.length()].to_owned()
  Ok(true)
}

///|
/// Frames the bytes for the transport this connection speaks: raw MFS
/// for a CLI, a WebSocket binary frame for a browser.
fn queue(conn : HubConnection, bytes : Bytes) -> Unit {
  let framed = if conn.kind == "websocket" {
    ws_encode_frame(WS_BINARY, bytes)
  } else {
    bytes
  }
  conn.outbox = append(conn.outbox, framed)
  if conn.outbox.length() > MAX_OUTBOX_BYTES {
    note(
      "peer is not reading (\{conn.outbox.length()} bytes queued); dropping it",
    )
    conn.phase = Closed
  }
}

///|
/// Writes what is queued, tolerating a full socket buffer: whatever
/// does not fit stays queued for the next pass. A blocking write here
/// would reintroduce exactly the starvation this hub exists to remove.
fn flush(conn : HubConnection) -> Result[Unit, String] {
  while conn.outbox.length() > 0 {
    match conn.stream.send_some(conn.outbox) {
      Ok(0) => return Ok(()) // socket buffer full; try next pass
      Ok(n) => conn.outbox = conn.outbox[n:conn.outbox.length()].to_owned()
      Err(WouldBlock) => return Ok(())
      Err(e) => return Err("\{e}")
    }
  }
  Ok(())
}

///|
fn append(a : Bytes, b : Bytes) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_bytes(a[0:a.length()])
  buf.write_bytes(b[0:b.length()])
  buf.to_bytes()
}

///|
/// The buffer the session's frame parser reads from: raw socket bytes
/// for a CLI, unwrapped WebSocket payloads for a browser.
fn HubConnection::source(self : HubConnection) -> Bytes {
  if self.kind == "websocket" {
    self.decoded
  } else {
    self.inbox
  }
}

///|
/// Drops `n` consumed bytes from that same buffer.
fn HubConnection::consume(self : HubConnection, n : Int) -> Unit {
  if self.kind == "websocket" {
    self.decoded = self.decoded[n:self.decoded.length()].to_owned()
  } else {
    self.inbox = self.inbox[n:self.inbox.length()].to_owned()
  }
}

///|
/// Unwraps every complete WebSocket frame currently buffered into the
/// decoded buffer, answering pings and honouring close. Returns when a
/// frame is incomplete (its bytes stay in the inbox for the next pass).
fn drain_ws_frames(conn : HubConnection) -> Result[Unit, String] {
  let mut more = true
  while more {
    match unwrap_ws_frame(conn) {
      Ok(consumed) => more = consumed
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// One WebSocket frame out of the inbox. Returns false when the frame is
/// not fully here yet.
fn unwrap_ws_frame(conn : HubConnection) -> Result[Bool, String] {
  if conn.inbox.length() < 2 {
    return Ok(false)
  }
  let opcode = (conn.inbox[0] & 0x0F).to_int()
  let masked = (conn.inbox[1] & 0x80) != b'\x00'
  let mut len = (conn.inbox[1] & 0x7F).to_int()
  let mut header = 2
  if len == 126 {
    if conn.inbox.length() < 4 {
      return Ok(false)
    }
    len = (conn.inbox[2].to_int() << 8) | conn.inbox[3].to_int()
    header = 4
  } else if len == 127 {
    if conn.inbox.length() < 10 {
      return Ok(false)
    }
    let mut big : Int64 = 0L
    for i in 0..<8 {
      big = (big << 8) | conn.inbox[2 + i].to_int64()
    }
    if big > 67108864L {
      return Err("websocket frame larger than the 64MiB cap")
    }
    len = big.to_int()
    header = 10
  }
  if !masked {
    return Err("client frames must be masked (RFC 6455 §5.1)")
  }
  let total = header + 4 + len
  if conn.inbox.length() < total {
    return Ok(false)
  }
  let mask = conn.inbox[header:header + 4]
  let unmasked : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    unmasked[i] = (conn.inbox[header + 4 + i].to_uint() ^ mask[i % 4].to_uint()).to_byte()
  }
  conn.inbox = conn.inbox[total:conn.inbox.length()].to_owned()
  match opcode {
    WS_BINARY | WS_TEXT | WS_CONTINUATION => {
      conn.decoded = append(conn.decoded, Bytes::from_array(unmasked))
      Ok(true)
    }
    WS_PING => {
      queue(conn, ws_encode_frame(WS_PONG, Bytes::from_array(unmasked)))
      Ok(true)
    }
    WS_PONG => Ok(true)
    WS_CLOSE => {
      queue(conn, ws_encode_frame(WS_CLOSE, b""))
      conn.phase = Closed
      Ok(true)
    }
    other => Err("unsupported websocket opcode \{other}")
  }
}
