// SPDX-License-Identifier: Apache-2.0
// The follower's persistent link to a partition's leader (P10).
//
// Replication used to open a connection per round: connect, handshake,
// ask, close. That is three round trips of connection churn per
// partition per tick, and with per-partition fan-out it is the largest
// remaining per-tick cost (decision 30 left it as the follow-up).
//
// A `SyncLink` keeps the connection: handshake once, then one request
// and one reply per round. Two rules keep it honest:
//
//   * **any error drops the link.** A timed-out request may leave a
//     reply in flight, and reading that as the next request's answer
//     would be a silent protocol corruption — so a link that misbehaves
//     once is closed, and the next round dials again;
//   * **one request in flight.** The node is single-threaded, so the
//     request id is a constant and the reply ordering is trivially
//     right; if that ever stops being true, this is where it breaks.

///|
/// A connection to one peer, reused across rounds.
pub struct SyncLink {
  address : String
  /// what to present on (re)dial (P12): credential and transport
  link : PeerLink
  /// The stream the link speaks over: a plain socket, or a TLS session
  /// over one. The wait loop is identical for both — it polls the
  /// descriptor and consults `pending`, which is exactly why the TLS
  /// session is behind this interface rather than special-cased here.
  stream : @net.Stream
  /// the TLS context, when this link is TLS: it must outlive the session,
  /// and nothing else holds it (the session does not own its context)
  tls : @tls.TlsContext?
  /// bytes received beyond the last frame: the next reply may already
  /// be partially here, and dropping them would misparse the stream
  inbox : Array[Byte]
  /// how many times this link (or its predecessors) had to be dialled:
  /// reported so churn is visible instead of merely absent. Constant per
  /// incarnation — the node redials by dropping the link and dialling a
  /// fresh one next round, so this is the count at *this* dial.
  opens : Int
  mut rounds : Int
}

///|
/// Dials a peer and completes the handshake. The socket goes
/// non-blocking for the life of the link; waiting is done by pumping
/// (the node must keep serving its own connections while it waits —
/// that is what made the multi-partition ring work at all, decision 30).
fn SyncLink::connect(
  address : String,
  link_auth : PeerLink,
  pump : () -> Unit,
) -> Result[SyncLink, String] {
  let (host, port) = parse_listen_addr(address)
  let (stream, tls) = match dial_stream(host, port, link_auth) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  let link = SyncLink::{
    address,
    link: link_auth,
    stream,
    tls,
    inbox: [],
    opens: 1,
    rounds: 0,
  }
  // One handshake, then the link is ready for requests — and it is
  // pumped while it happens, like every other wait in this file.
  //
  // The first version did not pump here, on the reasoning that "nothing
  // of ours is in flight yet, so there is nothing of ours to serve". That
  // reasoning forgot the *peer*: while this node waits for a WELCOME, it
  // may be the very node someone else is waiting for. Three nodes each
  // dialling in a ring then wait on each other with nobody polling, and
  // the whole cluster goes deaf for the length of the deadline — repeated
  // every tick, because the links never come up (P13 found this by
  // sampling a stalled node: all of its time was in this function).
  let deadline = now_ms() + HANDSHAKE_TIMEOUT_MS.to_int64()
  match
    send_all(
      pump,
      stream,
      @client.encode_frame(@client.Frame::{
        cmd: @client.CMD_HELLO,
        rid: 0,
        payload: @client.encode_hello(1, 0),
      }),
      deadline,
    ) {
    Ok(_) => ()
    Err(e) => {
      link.close()
      return Err("hello: \{e}")
    }
  }
  let welcome = match await_frame(pump, stream, link.inbox, deadline) {
    Ok(frame) => frame
    Err(e) => {
      link.close()
      return Err("handshake: \{e}")
    }
  }
  if welcome.cmd == @client.CMD_ERR {
    let (code, message) = @client.decode_error(welcome.payload)
    link.close()
    return Err("handshake rejected (code \{code}): \{message}")
  }
  if welcome.cmd != @client.CMD_WELCOME {
    link.close()
    return Err("expected WELCOME, got cmd \{welcome.cmd}")
  }
  // the credential, once per link (P12): the handshake is the part the
  // link exists to pay for once, and authentication is part of it
  match link_auth.token {
    Some(token) => {
      match
        send_all(
          pump,
          stream,
          @client.encode_frame(@client.Frame::{
            cmd: @client.CMD_AUTH,
            rid: 0,
            payload: @utf8.encode(token[0:token.length()]),
          }),
          deadline,
        ) {
        Ok(_) => ()
        Err(e) => {
          link.close()
          return Err("auth: \{e}")
        }
      }
      let reply = match await_frame(pump, stream, link.inbox, deadline) {
        Ok(frame) => frame
        Err(e) => {
          link.close()
          return Err("auth: \{e}")
        }
      }
      if reply.cmd == @client.CMD_ERR {
        let (code, message) = @client.decode_error(reply.payload)
        link.close()
        return Err("authentication rejected (code \{code}): \{message}")
      }
    }
    None => ()
  }
  Ok(link)
}

///|
/// Dials a peer over the transport this node's link asks for: a plain
/// socket, or a TLS session over one (P12). Both come back non-blocking,
/// because everything above waits by polling.
fn dial_stream(
  host : String,
  port : Int,
  link : PeerLink,
) -> Result[(@net.Stream, @tls.TlsContext?), String] {
  match link.tls {
    None => {
      let stream = match @net.TcpStream::connect(host, port) {
        Ok(stream) => stream
        Err(e) => return Err("connect \{host}:\{port}: \{e}")
      }
      match stream.set_nonblocking(true) {
        Ok(_) => Ok((stream.stream(), None))
        Err(e) => {
          let _ = stream.close()
          Err("nonblocking: \{e}")
        }
      }
    }
    Some(options) =>
      match
        @native.tcp_tls_stream(
          host,
          port,
          options.ca,
          options.cert,
          options.key,
          HANDSHAKE_TIMEOUT_MS,
        ) {
        Ok((stream, context)) => Ok((stream, Some(context)))
        Err(e) => Err(e)
      }
  }
}

///|
/// How long a dial plus handshake may take. A listening peer accepts
/// from the backlog immediately, so this is a routing check (nothing
/// there), not a patience setting.
const HANDSHAKE_TIMEOUT_MS : Int = 1000

///|
/// Sends one request and waits for its reply, serving this node's own
/// connections while it waits. The handshake happened in `connect`:
/// the whole point of a link is that rounds after the first skip it.
fn SyncLink::call(
  self : SyncLink,
  pump : () -> Unit,
  cmd : Int,
  payload : Bytes,
  timeout_ms : Int,
) -> Result[Bytes, String] {
  let deadline = now_ms() + timeout_ms.to_int64()
  self.rounds = self.rounds + 1
  match
    send_all(
      pump,
      self.stream,
      @client.encode_frame(@client.Frame::{ cmd, rid: 1, payload }),
      deadline,
    ) {
    Ok(_) => ()
    Err(e) => return Err("send: \{e}")
  }
  let reply = match await_frame(pump, self.stream, self.inbox, deadline) {
    Ok(frame) => frame
    Err(e) => return Err("reply: \{e}")
  }
  if reply.cmd == @client.CMD_ERR {
    let (code, message) = @client.decode_error(reply.payload)
    return Err("rejected (code \{code}): \{message}")
  }
  Ok(reply.payload)
}

///|
fn SyncLink::close(self : SyncLink) -> Unit {
  (self.stream.close)()
  match self.tls {
    Some(context) => context.free()
    None => ()
  }
}

///|
/// Writes every byte, serving connections in between. Frames here are
/// small (a request is tens of bytes), so a partial write means the
/// peer's window is full — the loop gives it time and tries again.
fn send_all(
  pump : () -> Unit,
  stream : @net.Stream,
  bytes : Bytes,
  deadline : Int64,
) -> Result[Unit, String] {
  let mut sent = 0
  while sent < bytes.length() {
    match (stream.send_some)(bytes[sent:bytes.length()].to_owned()) {
      Ok(0) => return Err("peer closed while writing")
      Ok(n) => sent = sent + n
      Err(WouldBlock) => {
        pump()
        if now_ms() > deadline {
          return Err("write deadline")
        }
        let _ = @net.poll_fds([(stream.fd)()], 10, true)
      }
      Err(e) => return Err("\{e}")
    }
  } nobreak {
    Ok(())
  }
}

///|
/// Reads one complete frame, serving connections while it waits. The
/// buffer is the link's, so a frame split across reads — or a reply
/// that arrives while nobody is asking — survives.
fn await_frame(
  pump : () -> Unit,
  stream : @net.Stream,
  inbox : Array[Byte],
  deadline : Int64,
) -> Result[@client.Frame, String] {
  let chunk : FixedArray[Byte] = FixedArray::make(8192, b'\x00')
  while true {
    // Take every byte the peer has already sent *before* serving
    // anything. A reply is one frame that arrives in many chunks, and
    // pumping between chunks costs a poll tick each: with an 8 KiB
    // read and a 50ms pump, a 4 MiB sync reply could never land inside
    // the 2s peer deadline — the follower timed out on every round and
    // never caught up (P15 measured exactly that, with hw stuck at 0).
    let mut closed = false
    while true {
      match (stream.recv_some)(chunk, chunk.length()) {
        Ok(0) => {
          closed = true
          break
        }
        Ok(n) => {
          for i = 0; i < n; i = i + 1 {
            inbox.push(chunk[i])
          }
          if inbox.length() > @client.MAX_FRAME_PAYLOAD + 13 {
            return Err("peer sent an oversized frame")
          }
        }
        Err(WouldBlock) => break
        Err(e) => return Err("\{e}")
      }
    }
    if inbox.length() >= 13 {
      let head = Bytes::from_array(inbox[0:13])
      let (cmd, rid, payload_len) = match @client.decode_header(head) {
        Ok(parts) => parts
        Err(e) => return Err(e)
      }
      let total = 13 + payload_len
      if inbox.length() >= total {
        let payload = Bytes::from_array(inbox[13:total])
        // consume what was taken: the same buffer carries the *next*
        // reply, and leaving the bytes in place made the second wait
        // return the first frame again (P7: the fetch reply decoded as
        // a welcome payload)
        let rest : Array[Byte] = []
        for i = total; i < inbox.length(); i = i + 1 {
          rest.push(inbox[i])
        }
        inbox.clear()
        for b in rest {
          inbox.push(b)
        }
        return Ok(@client.Frame::{ cmd, rid, payload })
      }
    }
    if closed {
      // a closed peer with a partial frame in hand is a failed call
      // either way: the caller must not treat a truncated reply as a
      // short one
      return Err("peer closed")
    }
    // not there yet: serve our own connections, then look again
    pump()
    if now_ms() > deadline {
      return Err("deadline")
    }
    // decrypted bytes count as readable: a TLS session can hold a whole
    // reply while its socket has nothing left to report
    if (stream.pending)() > 0 {
      // fall through to the read below without waiting
    } else {
      let ready = match @net.poll_fds([(stream.fd)()], 10, false) {
        Ok(ready) => ready
        Err(e) => return Err("\{e}")
      }
      if ready.length() == 0 {
        continue
      }
    }
  } nobreak {
    Err(
      // unreachable: every exit above is a return
      "unreachable",
    )
  }
}
