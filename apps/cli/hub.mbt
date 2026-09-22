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
/// How much one connection may buffer before the hub gives up on it:
/// one protocol batch — the largest data frame a peer has any business
/// sending — plus an envelope's worth of slack (frame header, topic
/// name, a WebSocket header).
///
/// It used to be a hand-written 8 MiB, which sat *below* the 16 MiB
/// batch the decoder accepts. An 8.7 MiB produce was therefore refused
/// by a cap the sender could not know about, and the refusal looked
/// like a connection reset with nothing in the log (P15). A transport
/// may not be stricter than the protocol it carries without saying so;
/// now the bound is derived from the protocol, and crossing it is
/// reported rather than silent.
const MAX_INBOX_BYTES : Int = @protocol.MAX_BATCH_BYTES + 1048576

///|
/// The same bound for the write side. The server's own largest reply is
/// one batch frame, so a peer that reads at all never reaches it; a
/// peer that has stopped reading is dropped instead of being allowed to
/// grow this process's heap. Reported, like the inbox.
const MAX_OUTBOX_BYTES : Int = @protocol.MAX_BATCH_BYTES + 1048576

///|
/// One served connection.
pub struct HubConnection {
  /// The plain socket under this connection: kept for polling, even
  /// when the bytes themselves travel through a TLS session.
  socket : @net.TcpStream
  /// What the layers above actually read and write: a plain socket, or a
  /// TLS session over it (P12), decided once when the connection is
  /// adopted.
  stream : @net.Stream
  /// The TLS session while it is being negotiated, and afterwards.
  tls : @tls.TlsSession?
  /// bytes read from the socket, not yet consumed by the parser
  mut inbox : Bytes
  /// bytes read this round, not yet joined into `inbox`. Kept apart
  /// because joining on every read made receiving a batch quadratic —
  /// 8 KiB reads copied a 17 MiB buffer 2,000 times, and a 20 MiB
  /// produce took ten seconds of pure memcpy (P15). One join per poll
  /// round costs the same bytes once.
  mut pending : Array[Bytes]
  /// how many bytes `pending` holds
  mut pending_len : Int
  /// for WebSocket connections: payload bytes unwrapped from WS frames,
  /// waiting for the frame parser. A WS frame is *envelope*, the bytes
  /// inside it are the session's frames — conflating the two makes every
  /// command look like it has cmd 0 (which is what the first cut did).
  mut decoded : Bytes
  /// replies queued for this peer, not yet written
  mut outbox : Bytes
  /// the session state: what this connection speaks and where it is
  mut phase : Phase
  /// who this connection is, once it has said so (P12). `None` while
  /// unauthenticated: the transport refuses to serve commands then, so
  /// a handler never sees `None` on a path that requires an identity.
  mut identity : @auth.Identity?
  /// when the TLS handshake must be finished by (0 for plaintext). A
  /// deadline the *loop* checks, not one the socket enforces: no call in
  /// this file waits for a peer any more.
  tls_deadline : Int64
  /// the configured handshake window, for the log line when it expires
  window_hint_ms : Int
  /// a label for logs: "tcp" or "websocket"
  mut kind : String
}

///|
pub(all) enum Phase {
  /// A TLS session is being negotiated on this connection. It is stepped
  /// once per poll round and never waited on (P13): waiting is what made
  /// a peer that connects and says nothing expensive.
  TlsHandshake
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
  ///
  /// The identity is the *connection's*, resolved by the AUTH exchange
  /// this layer owns (it already owns the handshake): `None` means the
  /// session has not authenticated, and a handler that needs an
  /// identity must say so rather than invent one.
  on_frame : (@client.Frame, @auth.Identity?) -> @client.Frame
  /// Called once the handshake completes (after WELCOME is queued).
  on_ready : () -> Unit
  /// The node's credential table. Owned here because *this* is the
  /// layer that knows whether a connection has presented a credential —
  /// per-connection session state, which is precisely what the hub has
  /// and a dispatcher does not.
  auth : AuthGate
}

///|
/// The hub: an accept backlog plus every connection currently open.
pub struct ConnectionHub {
  listener : @net.TcpListener
  /// Present when this listener speaks TLS (P12). The hub does not care
  /// beyond "attach a session and drive it": TLS is a property of the
  /// transport, and the protocol above is identical.
  tls : @tls.TlsContext?
  mut conns : Array[HubConnection]
  /// the longest frame header + the largest payload this server accepts
  max_frame : Int
  poll_timeout_ms : Int
  /// how long one accepted connection may spend in its TLS handshake.
  /// A parameter, not a constant, because the cost of a peer that
  /// connects and says nothing is paid by the *loop*: the control plane
  /// keeps a 3s liveness window, so it takes a tighter bound than a data
  /// port whose peers are all nodes it already knows.
  handshake_deadline_ms : Int
}

///|
pub fn ConnectionHub::new(
  listener : @net.TcpListener,
  poll_timeout_ms : Int,
) -> ConnectionHub {
  ConnectionHub::{
    listener,
    tls: None,
    conns: [],
    max_frame: @client.MAX_FRAME_PAYLOAD + 13,
    poll_timeout_ms,
    handshake_deadline_ms: HANDSHAKE_DEADLINE_MS,
  }
}

///|
/// The same hub, speaking TLS on this listener.
pub fn ConnectionHub::with_tls(
  self : ConnectionHub,
  tls : @tls.TlsContext,
) -> ConnectionHub {
  ConnectionHub::{
    listener: self.listener,
    tls: Some(tls),
    conns: self.conns,
    max_frame: self.max_frame,
    poll_timeout_ms: self.poll_timeout_ms,
    handshake_deadline_ms: self.handshake_deadline_ms,
  }
}

///|
/// The same hub, with a tighter handshake bound. See
/// `handshake_deadline_ms`: this is the knob that decides how much a
/// peer that connects and says nothing can cost the loop.
pub fn ConnectionHub::with_handshake_deadline(
  self : ConnectionHub,
  ms : Int,
) -> ConnectionHub {
  ConnectionHub::{
    listener: self.listener,
    tls: self.tls,
    conns: self.conns,
    max_frame: self.max_frame,
    poll_timeout_ms: self.poll_timeout_ms,
    handshake_deadline_ms: ms,
  }
}

///|
/// Registers an accepted stream as a connection.
///
/// The TLS handshake is **stepped, not waited on** (P13). The session is
/// attached here and driven one step per poll round from `service`; the
/// deadline below is checked by the loop. The first design ran the
/// handshake to completion here with a receive deadline, which is simpler
/// to read and was wrong in the way that matters: a peer that connects
/// and says nothing held the loop for the whole deadline, and enough of
/// them starved the connections that had real work (a measured failure —
/// a live node was declared dead). Bounding how many such waits a round
/// may do only converts it into head-of-line blocking, because the stalled
/// peer sits at the front of the backlog. Not waiting at all is the fix.
fn ConnectionHub::adopt(self : ConnectionHub, stream : @net.TcpStream) -> Unit {
  // non-blocking *before* the session is attached: every SSL call must
  // return "wants more" rather than block, which is what lets the loop
  // step it
  match stream.set_nonblocking(true) {
    Ok(_) => ()
    Err(e) => {
      note("dropping a connection: cannot go non-blocking (\{e})")
      return
    }
  }
  match self.tls {
    None =>
      self.conns.push(HubConnection::{
        socket: stream,
        stream: stream.stream(),
        tls: None,
        inbox: b"",
        pending: [],
        pending_len: 0,
        decoded: b"",
        outbox: b"",
        phase: Handshake,
        tls_deadline: 0L,
        window_hint_ms: 0,
        kind: "tcp",
        identity: None,
      })
    Some(context) => {
      let attached = match context.attach(stream.raw_fd()) {
        Ok(attached) => attached
        Err(e) => {
          note("dropping a connection: \{e}")
          let _ = stream.close()
          return
        }
      }
      self.conns.push(HubConnection::{
        socket: stream,
        stream: @native.tls_stream_over(stream, attached),
        tls: Some(attached),
        inbox: b"",
        pending: [],
        pending_len: 0,
        decoded: b"",
        outbox: b"",
        phase: TlsHandshake,
        tls_deadline: now_ms() + self.handshake_deadline_ms.to_int64(),
        window_hint_ms: self.handshake_deadline_ms,
        kind: "tls",
        identity: None,
      })
    }
  }
}

///|
/// The deadline this connection was given, for the log line. Kept as a
/// derived read rather than a second stored field: two copies of a
/// number is one copy too many.
fn HubConnection::handshake_ms_hint(self : HubConnection) -> Int {
  self.window_hint_ms
}

///|
/// One step of a TLS handshake. `true` when the connection moved on (or
/// was dropped), so the caller knows whether its phase changed.
fn step_handshake(conn : HubConnection) -> Unit {
  let session = match conn.tls {
    Some(session) => session
    None => {
      conn.phase = Handshake
      return
    }
  }
  match session.accept() {
    Ok(Done) => conn.phase = Handshake
    Ok(Pending(_)) =>
      // nothing to do: the next round steps it again. There is no
      // direction to poll for here — SSL_accept reads and writes the
      // socket itself, and a step that is not ready costs nothing.
      if conn.tls_deadline != 0L && now_ms() > conn.tls_deadline {
        note(
          "dropping a connection: TLS handshake did not finish within \{conn.handshake_ms_hint()}ms",
        )
        conn.phase = Closed
      }
    Err(e) => {
      note("TLS handshake failed: \{e}")
      conn.phase = Closed
    }
  }
}

///|
/// How long a TLS handshake may take before the connection is dropped.
const HANDSHAKE_DEADLINE_MS : Int = 2000

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
  //    the next tick just because one connection is busy. Accepting is
  //    cheap now, TLS included — the handshake is attached and then
  //    *stepped* (see `adopt`), so there is no wait to budget for.
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
  // 1b. advance every TLS session that is still negotiating. This is the
  //     whole of the handshake as far as a peer can see: a step that is
  //     not ready returns immediately, so a peer that says nothing costs
  //     one call per round until its deadline — not a stalled loop.
  for conn in self.conns {
    if conn.phase is TlsHandshake {
      step_handshake(conn)
    }
  }
  if self.conns.length() == 0 {
    // nothing to serve: sleep out the tick so the caller's housekeeping
    // (heartbeats, reconcile) still happens on schedule
    let _ = @net.poll_readable([], self.poll_timeout_ms)
    return 0
  }
  // 2. find out which connections have something
  let fds : Array[Int] = []
  for conn in self.conns {
    fds.push((conn.stream.fd)())
  }
  let ready = match @net.poll_fds(fds, self.poll_timeout_ms, false) {
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
    if conn.phase is TlsHandshake {
      // its bytes belong to the handshake, not to the protocol above it
      continue
    }
    match read_available(conn) {
      Ok(_) => ()
      Err(e) =>
        if !(conn.phase is Closed) {
          // A reset after a completed handshake is an ordinary
          // disconnect (a peer that closed with data still queued), and
          // a data node sees one per replication round: logging those
          // would be a line per partition per tick (P7).
          if !(conn.phase is Frames) {
            note("connection (\{conn.kind}) closed: \{e}")
          }
          conn.phase = Closed
        }
    }
  }
  for i in 0..<self.conns.length() {
    if self.conns[i].phase is Closed || self.conns[i].phase is TlsHandshake {
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
      (conn.stream.close)()
      continue
    }
    if conn.phase is TlsHandshake {
      // nothing can be written before the session is up
      alive.push(conn)
      continue
    }
    match flush(conn) {
      Ok(_) => alive.push(conn)
      Err(e) => {
        note("connection (\{conn.kind}) dropped while writing: \{e}")
        (conn.stream.close)()
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
  let buf : FixedArray[Byte] = FixedArray::make(READ_CHUNK_BYTES, b'\x00')
  while true {
    match (conn.stream.recv_some)(buf, buf.length()) {
      Ok(0) => {
        conn.phase = Closed
        return Ok(())
      }
      Ok(n) => {
        // stash the chunk; the join happens once per round, not once
        // per read (see `pending`)
        conn.pending.push(Bytes::from_array(buf[0:n]))
        conn.pending_len += n
        if conn.inbox.length() + conn.pending_len > MAX_INBOX_BYTES {
          // loud on purpose: this is the one read outcome that used to
          // be indistinguishable from a peer that simply went away, and
          // an operator staring at a client-side "connection reset" has
          // nothing else to go on (P15)
          note(
            "dropping \{conn.kind} connection: \{conn.inbox.length() + conn.pending_len} bytes buffered with no complete request (limit \{MAX_INBOX_BYTES}); the largest frame this server accepts is one \{@protocol.MAX_BATCH_BYTES}-byte batch",
          )
          return Err(
            "peer sent \{conn.inbox.length() + conn.pending_len} bytes without a complete request",
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
/// How much one socket read takes. Large enough that a batch is a few
/// reads rather than a few thousand (which is what made the join cost
/// visible in the first place), small enough to stay a buffer and not
/// an allocation.
const READ_CHUNK_BYTES : Int = 65536

///|
/// Joins this round's reads into the contiguous inbox the parser needs.
/// Called once per connection per round: the copy happens at most once
/// per poll, whatever the peer's write pattern was.
fn HubConnection::materialize(self : HubConnection) -> Unit {
  if self.pending.length() == 0 {
    return
  }
  if self.inbox.length() == 0 && self.pending.length() == 1 {
    // a frame that arrived in one read: no copy at all
    self.inbox = self.pending[0]
  } else {
    let merged = @buffer.Buffer::Buffer()
    merged.write_bytes(self.inbox[0:self.inbox.length()])
    for chunk in self.pending {
      merged.write_bytes(chunk[0:chunk.length()])
    }
    self.inbox = merged.to_bytes()
  }
  self.pending = []
  self.pending_len = 0
}

///|
/// Drives the connection's protocol state machine over whatever is
/// buffered. HTTP upgrades and frame sessions both live here, so a
/// browser and a CLI are served by the same code path from the same
/// loop.
fn service(conn : HubConnection, handler : HubHandler) -> Unit {
  conn.materialize()
  match conn.phase {
    TlsHandshake =>
      // handled by `step_handshake` in the poll loop, before this runs
      ()
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
          let reply = (handler.on_frame)(frame, conn.identity)
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
        // the credential exchange is the *transport's* business (P12):
        // it is per-connection session state, and it must happen before
        // any command reaches a handler
        if frame.cmd == @client.CMD_AUTH {
          let token = @utf8.decode_lossy(
            frame.payload[0:frame.payload.length()],
          )
          let reply = match handler.auth.present(token) {
            Accepted(identity) => {
              conn.identity = Some(identity)
              note(
                "connection authenticated as \{identity.name} (\{@auth.role_name(identity.role)})",
              )
              @client.Frame::{
                cmd: @client.CMD_OK,
                rid: frame.rid,
                payload: @utf8.encode(@auth.role_name(identity.role)),
              }
            }
            NotRequired =>
              // no credentials configured on this node: the session is
              // trusted (and says so), so permission checks still have
              // a role to work with
              @client.Frame::{
                cmd: @client.CMD_OK,
                rid: frame.rid,
                payload: @utf8.encode("none"),
              }
            Rejected(reason) =>
              @client.Frame::{
                cmd: @client.CMD_ERR,
                rid: frame.rid,
                payload: @client.encode_error(
                  @client.ERR_AUTH_REQUIRED,
                  "\{reason}: this node requires a valid credential",
                ),
              }
          }
          queue(conn, @client.encode_frame_bytes(reply))
          if reply.cmd == @client.CMD_ERR {
            conn.phase = Closed
            return
          }
          continue
        }
        // everything else waits until the session is identified
        if handler.auth.config.required() && conn.identity is None {
          let reply = @client.Frame::{
            cmd: @client.CMD_ERR,
            rid: frame.rid,
            payload: @client.encode_error(
              @client.ERR_AUTH_REQUIRED,
              "authenticate first: send CMD_AUTH with this node's credential",
            ),
          }
          queue(conn, @client.encode_frame_bytes(reply))
          conn.phase = Closed
          return
        }
        let reply = (handler.on_frame)(frame, conn.identity)
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
    match (conn.stream.send_some)(conn.outbox) {
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
