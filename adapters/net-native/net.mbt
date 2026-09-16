// SPDX-License-Identifier: Apache-2.0
// Structured facade over the raw socket FFI.

///|
/// Failure modes of the native network adapter. `code` carries
/// errno; `op` names the operation.
pub(all) suberror NetError {
  /// Host or address rejected before any syscall.
  BadAddress(String)
  /// Underlying syscall failed; `code` is errno.
  Io(Int, String)
  /// Peer closed the connection mid-exchange.
  ConnectionClosed
  /// The socket's timeout (see `TcpStream::set_recv_timeout_ms`)
  /// expired before any data arrived. Distinct from an error so a
  /// single-threaded node loop can treat it as "time to do housekeeping"
  /// rather than as a failure.
  TimedOut
} derive(Debug, Eq)

///|
pub impl Show for NetError with fn output(self, logger) {
  match self {
    BadAddress(msg) => logger.write_string("BadAddress(\{msg})")
    Io(code, op) => logger.write_string("Io(errno=\{code}, op=\{op})")
    ConnectionClosed => logger.write_string("ConnectionClosed")
    TimedOut => logger.write_string("TimedOut")
  }
}

///|
/// The shim's dedicated timeout code (see net_shim.c): a socket
/// deadline that expired, not a failure.
const NET_TIMEOUT_CODE : Int = 9999

///|
/// Wraps a raw FFI result: negative means -errno, except the shim's
/// timeout sentinel, which becomes `TimedOut`.
fn io_result(code : Int, op : String) -> Result[Int, NetError] {
  if code < 0 {
    if -code == NET_TIMEOUT_CODE {
      Err(TimedOut)
    } else {
      Err(Io(-code, op))
    }
  } else {
    Ok(code)
  }
}

///|
fn host_bytes(host : String) -> Result[Bytes, NetError] {
  let bytes = @utf8.encode(host[0:host.length()])
  if bytes.length() == 0 || bytes.length() >= 512 {
    return Err(BadAddress("host length must be 1..511"))
  }
  Ok(bytes)
}

///|
/// A connected TCP socket. Blocking IO; not thread-safe by design.
pub struct TcpStream {
  fd : Int
} derive(Debug)

///|
/// A listening TCP socket awaiting `accept`. `accept_timeout_ms` is
/// carried here because the deadline is a property of the accept
/// call, not of the socket: macOS ignores SO_RCVTIMEO for accept, so
/// the listener holds the deadline and `accept` passes it down to a
/// poll()-based shim call.
pub struct TcpListener {
  fd : Int
  mut accept_timeout_ms : Int
} derive(Debug)

///|
/// Connects to `host:port` (host may be a name or numeric address).
pub fn TcpStream::connect(
  host : String,
  port : Int,
) -> Result[TcpStream, NetError] {
  if port <= 0 || port > 65535 {
    return Err(BadAddress("port must be 1..65535"))
  }
  let h = match host_bytes(host) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  match io_result(net_connect(h, h.length(), port), "connect") {
    Ok(fd) => Ok(TcpStream::{ fd, })
    Err(e) => Err(e)
  }
}

///|
/// Wraps a raw fd (from `accept` or `socketpair`) as a stream.
pub fn TcpStream::from_fd(fd : Int) -> TcpStream {
  TcpStream::{ fd, }
}

///|
/// The raw descriptor (escape hatch for tests).
pub fn TcpStream::raw_fd(self : TcpStream) -> Int {
  self.fd
}

///|
/// Sends every byte of `data`, looping until done; returns the
/// number of bytes sent (== data.length()).
pub fn TcpStream::send_all(
  self : TcpStream,
  data : Bytes,
) -> Result[Int, NetError] {
  let total = data.length()
  let mut sent = 0
  while sent < total {
    let view = data[sent:total].to_owned()
    let n = net_send(self.fd, view, view.length())
    if n < 0 {
      return Err(Io(-n, "send"))
    }
    if n == 0 {
      return Err(ConnectionClosed)
    }
    sent += n
  }
  Ok(sent)
}

///|
/// Receives up to `len` bytes into `buf`; returns the number of
/// bytes received, 0 meaning clean end-of-stream by the peer.
pub fn TcpStream::recv(
  self : TcpStream,
  buf : FixedArray[Byte],
  len : Int,
) -> Result[Int, NetError] {
  if len < 0 || len > buf.length() {
    return Err(BadAddress("recv bounds"))
  }
  let n = net_recv(self.fd, buf, len)
  if n < 0 {
    if -n == NET_TIMEOUT_CODE {
      return Err(TimedOut)
    }
    return Err(Io(-n, "recv"))
  }
  Ok(n)
}

///|
/// Sets a receive timeout in milliseconds (0 clears it). A single-
/// threaded node loop uses this on its listener so `accept` returns
/// `TimedOut` instead of blocking forever, which is what makes
/// "serve requests, then do housekeeping" possible without threads —
/// housekeeping is exactly the control-plane work (heartbeats, liveness
/// sweeps, reconcile ticks) that must not be starved by an idle socket.
pub fn TcpStream::set_recv_timeout_ms(
  self : TcpStream,
  ms : Int,
) -> Result[Unit, NetError] {
  if ms < 0 {
    return Err(BadAddress("timeout must not be negative"))
  }
  match io_result(net_set_recv_timeout(self.fd, ms), "setsockopt") {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Installs an accept deadline in milliseconds (0 = block forever).
/// Deliberately not a socket option: macOS ignores SO_RCVTIMEO for
/// accept, so the deadline is stored on the listener and passed to a
/// poll()-based shim call.
pub fn TcpListener::set_accept_timeout_ms(
  self : TcpListener,
  ms : Int,
) -> Result[Unit, NetError] {
  if ms < 0 {
    return Err(BadAddress("timeout must not be negative"))
  }
  self.accept_timeout_ms = ms
  Ok(())
}

///|
/// Closes the socket.
pub fn TcpStream::close(self : TcpStream) -> Result[Unit, NetError] {
  match io_result(net_close(self.fd), "close") {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Binds `host:port` and starts listening (backlog 16). Pass port 0
/// to let the OS assign one; combine with `local_port`.
pub fn TcpListener::bind_listen(
  host : String,
  port : Int,
) -> Result[TcpListener, NetError] {
  if port < 0 || port > 65535 {
    return Err(BadAddress("port must be 0..65535"))
  }
  let h = match host_bytes(host) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  match io_result(net_bind_listen(h, h.length(), port), "bind") {
    Ok(fd) => Ok(TcpListener::{ fd, accept_timeout_ms: 0 })
    Err(e) => Err(e)
  }
}

///|
/// The actual bound port (after an OS-assigned bind).
pub fn TcpListener::local_port(self : TcpListener) -> Result[Int, NetError] {
  match io_result(net_getsockport(self.fd), "getsockname") {
    Ok(port) => Ok(port)
    Err(e) => Err(e)
  }
}

///|
/// Blocks until a peer connects; returns the accepted stream. With a
/// timeout installed via `set_accept_timeout_ms` it returns `TimedOut`
/// instead, which is what lets a single-threaded node alternate
/// between serving and housekeeping.
pub fn TcpListener::accept(self : TcpListener) -> Result[TcpStream, NetError] {
  match
    io_result(net_accept_timeout(self.fd, self.accept_timeout_ms), "accept") {
    Ok(fd) => Ok(TcpStream::{ fd, })
    Err(e) => Err(e)
  }
}

///|
/// Closes the listener (accepted streams are independent).
pub fn TcpListener::close(self : TcpListener) -> Result[Unit, NetError] {
  match io_result(net_close(self.fd), "close") {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Creates a connected AF_UNIX socket pair for in-process tests.
/// Both ends behave like streams: send on one, recv on the other.
pub fn socketpair() -> Result[(TcpStream, TcpStream), NetError] {
  let pair : FixedArray[Int] = FixedArray::make(2, 0)
  match io_result(net_socketpair(pair), "socketpair") {
    Ok(_) => Ok((TcpStream::{ fd: pair[0] }, TcpStream::{ fd: pair[1] }))
    Err(e) => Err(e)
  }
}
