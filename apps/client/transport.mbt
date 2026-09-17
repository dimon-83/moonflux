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
