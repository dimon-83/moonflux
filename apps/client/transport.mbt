// SPDX-License-Identifier: Apache-2.0
// apps/client: the native transport. The client logic (frame codec,
// session state machine) lives in core/client, which compiles for
// every backend; this package supplies sockets only.
//
// Callers that need both import both: `core/client` for the protocol
// and the Producer/Consumer session, this package for the TCP and
// socketpair constructors. That is intentional — a transport is not a
// client, and a browser will import the kernel plus its own transport.

///|
/// Local names for the kernel's types: this package's signatures speak
/// `Conn`/`Producer`/`Consumer`, which belong to core/client.
pub using @kernel {type Conn, type Producer, type Consumer, type ClientError}

///|
/// Adapts a native TCP stream to the transport contract. `recv_exact`
/// loops because a socket read may return short; a clean EOF before
/// `n` bytes is an error, never a silent short read.
fn wrap_stream(stream : @net.TcpStream) -> Conn {
  Conn::{
    send: fn(bytes) {
      match stream.send_all(bytes) {
        Ok(_) => Ok(())
        Err(e) => Err("\{e}")
      }
    },
    recv_exact: fn(n) {
      let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
      let mut filled = 0
      while filled < n {
        let got = match stream.recv(buf, n) {
          Ok(got) => got
          Err(e) => return Err("\{e}")
        }
        if got == 0 {
          return Err("connection closed after \{filled} of \{n} bytes")
        }
        filled += got
      }
      Ok(Bytes::from_array(buf[0:n]))
    },
    close: fn() { let _ = stream.close() },
  }
}

///|
/// Wraps an accepted server-side stream as a Conn.
pub fn from_stream(stream : @net.TcpStream) -> Conn {
  wrap_stream(stream)
}

///|
/// Opens a blocking TCP connection.
pub fn tcp(host : String, port : Int) -> Result[Conn, String] {
  match @net.TcpStream::connect(host, port) {
    Ok(stream) => Ok(wrap_stream(stream))
    Err(e) => Err("connect \{host}:\{port}: \{e}")
  }
}

///|
/// Adapts any stream to the transport contract, with a deadline: a read
/// that gets nothing for `timeout_ms` fails instead of waiting. Plain
/// sockets already had this (`tcp_with_timeout` sets SO_RCVTIMEO); a TLS
/// session has no such socket option, so the wait has to be a deadline
/// the loop enforces (P12/T59). Without it, a node talking TLS to a hung
/// peer waits forever — and "no node may hang another" is the property
/// this deadline design exists for. `timeout_ms <= 0` means no deadline,
/// which is what a client with nothing else to serve asks for.
pub fn conn_over_stream(stream : @net.Stream, timeout_ms : Int) -> Conn {
  Conn::{
    send: fn(bytes) {
      let deadline = if timeout_ms > 0 {
        deadline_after(timeout_ms)
      } else {
        0L
      }
      let mut sent = 0
      while sent < bytes.length() {
        match (stream.send_some)(bytes[sent:bytes.length()].to_owned()) {
          Ok(0) => return Err("peer closed while sending")
          Ok(n) => sent = sent + n
          Err(@net.WouldBlock) => {
            let _ = @net.poll_fds([(stream.fd)()], 50, true)
            if timeout_ms > 0 && past_deadline(deadline) {
              return Err("send timed out after \{timeout_ms}ms")
            }
          }
          Err(e) => return Err("\{e}")
        }
      }
      Ok(())
    },
    recv_exact: fn(n) {
      let deadline = if timeout_ms > 0 {
        deadline_after(timeout_ms)
      } else {
        0L
      }
      let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
      let mut filled = 0
      while filled < n {
        match (stream.recv_some)(buf, n - filled) {
          Ok(0) => return Err("connection closed after \{filled} of \{n} bytes")
          Ok(got) => filled = filled + got
          Err(@net.WouldBlock) => {
            let _ = @net.poll_fds([(stream.fd)()], 50, false)
            if timeout_ms > 0 && past_deadline(deadline) {
              return Err("read timed out after \{timeout_ms}ms")
            }
          }
          Err(e) => return Err("\{e}")
        }
      }
      Ok(Bytes::from_array(buf[0:n]))
    },
    close: fn() { (stream.close)() },
  }
}

///|
/// The stream a TLS session presents to the layers above it (P12). The
/// session owns decrypted bytes that the socket does not report, so
/// `pending` matters: a poll loop that watched only the socket would
/// sleep through them.
pub fn tls_stream_over(
  socket : @net.TcpStream,
  session : @tls.TlsSession,
) -> @net.Stream {
  @net.Stream::{
    fd: fn() { socket.raw_fd() },
    recv_some: fn(buf, len) {
      match session.read_some(buf, len) {
        Ok(Some(got)) => Ok(got)
        // "wants more" is what a plain socket calls would-block, so the
        // three states the event loop distinguishes stay distinguishable
        Ok(None) => Err(@net.WouldBlock)
        Err(e) => Err(@net.Io(0, e))
      }
    },
    send_some: fn(bytes) {
      match session.write_some(bytes) {
        Ok(Some(got)) => Ok(got)
        Ok(None) => Err(@net.WouldBlock)
        Err(e) => Err(@net.Io(0, e))
      }
    },
    pending: fn() { session.pending() },
    set_nonblocking: fn(enabled) { socket.set_nonblocking(enabled) },
    close: fn() {
      session.close()
      let _ = socket.close()
    },
  }
}

///|
/// Dials a peer, negotiates TLS, and hands back the **non-blocking**
/// stream — what the replication link needs, because it waits by polling
/// the node's own loop rather than by blocking (P10's shape, now over
/// TLS). The caller owns the returned context: it must outlive the
/// session, so the link keeps it and frees it when it closes.
pub fn tcp_tls_stream(
  host : String,
  port : Int,
  ca : String,
  cert : String?,
  key : String?,
  handshake_timeout_ms : Int,
) -> Result[(@net.Stream, @tls.TlsContext), String] {
  match tls_handshake(host, port, ca, cert, key, handshake_timeout_ms) {
    Ok((socket, session, context)) =>
      Ok((tls_stream_over(socket, session), context))
    Err(e) => Err(e)
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
pub fn tcp_with_timeout(
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
pub fn socketpair() -> Result[(Conn, Conn), String] {
  match @net.socketpair() {
    Ok((a, b)) => Ok((wrap_stream(a), wrap_stream(b)))
    Err(e) => Err("socketpair: \{e}")
  }
}

///|
/// Connects a producer over native TCP and performs the handshake,
/// presenting a credential when one is supplied (P12).
pub fn connect_producer_with(
  host : String,
  port : Int,
  token : String?,
) -> Result[Producer, ClientError] {
  let conn = match tcp(host, port) {
    Ok(conn) => conn
    Err(e) => return Err(@kernel.Transport(e))
  }
  Producer::from_conn_with(conn, token)
}

///|
/// Connects a producer over native TCP and performs the handshake.
pub fn connect_producer(
  host : String,
  port : Int,
) -> Result[Producer, ClientError] {
  connect_producer_with(host, port, None)
}

///|
/// Connects a consumer over native TCP and performs the handshake,
/// presenting a credential when one is supplied (P12).
pub fn connect_consumer_with(
  host : String,
  port : Int,
  token : String?,
) -> Result[Consumer, ClientError] {
  let conn = match tcp(host, port) {
    Ok(conn) => conn
    Err(e) => return Err(@kernel.Transport(e))
  }
  Consumer::from_conn_with(conn, token)
}

///|
/// Connects a consumer over native TCP and performs the handshake.
pub fn connect_consumer(
  host : String,
  port : Int,
) -> Result[Consumer, ClientError] {
  connect_consumer_with(host, port, None)
}

// ---------------------------------------------------------------------
// TLS (P12). The kernel's `Conn` is a struct of closures, so a TLS
// connection is a *constructor*, not a branch inside the protocol: the
// frames above are byte-identical whether they ride a plain socket or a
// session.
//
// The handshake runs cooperatively here too. It could block — this is a
// client, and it has nothing else to serve — but a client that hangs
// forever on a peer that never finishes saying hello is exactly the
// failure a deadline exists for, so the loop polls with one.

///|
/// Milliseconds from now, for a deadline. Read in this layer, never in
/// the kernel.
fn deadline_after(ms : Int) -> Int64 {
  @env.now().reinterpret_as_int64() + ms.to_int64()
}

///|
fn past_deadline(deadline : Int64) -> Bool {
  @env.now().reinterpret_as_int64() > deadline
}

///|
/// Dials `host:port` and negotiates TLS. `ca` is the trust anchor;
/// `cert`/`key` are an optional client certificate (for a node that must
/// present one). `timeout_ms = 0` means "no read deadline": a client with
/// nothing else to serve may wait, and only an explicit deadline (a node
/// talking to a peer) should expire.
pub fn tcp_tls(
  host : String,
  port : Int,
  ca : String,
  cert : String?,
  key : String?,
  handshake_timeout_ms : Int,
) -> Result[Conn, String] {
  tls_conn_with_timeout(host, port, ca, cert, key, handshake_timeout_ms, 0)
}

///|
/// The same dial with a deadline on every read and write that follows.
/// Node-to-node calls need this: the handshake being bounded is not
/// enough when the peer can go quiet *after* it.
pub fn tls_conn_with_timeout(
  host : String,
  port : Int,
  ca : String,
  cert : String?,
  key : String?,
  handshake_timeout_ms : Int,
  io_timeout_ms : Int,
) -> Result[Conn, String] {
  let (socket, session, context) = match
    tls_handshake(host, port, ca, cert, key, handshake_timeout_ms) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  let conn = conn_over_stream(tls_stream_over(socket, session), io_timeout_ms)
  // the context this call created is freed when the connection closes:
  // nobody else holds it, and the session is only valid while it lives
  Ok(Conn::{
    send: conn.send,
    recv_exact: conn.recv_exact,
    close: fn() {
      (conn.close)()
      context.free()
    },
  })
}

///|
/// Dials a peer, negotiates TLS, and hands back the pieces. The blocking
/// `Conn` and the non-blocking `Stream` constructors above are two views
/// of this one result, so the handshake — the part with the subtlety —
/// exists once.
fn tls_handshake(
  host : String,
  port : Int,
  ca : String,
  cert : String?,
  key : String?,
  timeout_ms : Int,
) -> Result[(@net.TcpStream, @tls.TlsSession, @tls.TlsContext), String] {
  let context = match @tls.client_context(ca, cert, key) {
    Ok(context) => context
    Err(e) => return Err(e)
  }
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => {
      context.free()
      return Err("connect \{host}:\{port}: \{e}")
    }
  }
  // non-blocking from here on: the handshake loop waits by polling and
  // enforcing its own deadline, and every read after it does the same
  match stream.set_nonblocking(true) {
    Ok(_) => ()
    Err(e) => {
      context.free()
      let _ = stream.close()
      return Err("nonblocking: \{e}")
    }
  }
  let session = match context.attach(stream.raw_fd()) {
    Ok(session) => session
    Err(e) => {
      context.free()
      let _ = stream.close()
      return Err(e)
    }
  }
  // the certificate must name the host we asked for
  session.set_host(host)
  let deadline = deadline_after(timeout_ms)
  let mut done = false
  let mut failure = ""
  while !done {
    match session.connect() {
      Ok(Done) => done = true
      Ok(Pending(want_write)) => {
        let _ = @net.poll_fds([stream.raw_fd()], 50, want_write)
        if past_deadline(deadline) {
          failure = "TLS handshake timed out"
          break
        }
      }
      Err(e) => {
        failure = e
        break
      }
    }
  }
  if !done {
    session.close()
    let _ = stream.close()
    context.free()
    return Err("TLS to \{host}:\{port}: \{failure}")
  }
  Ok((stream, session, context))
}
