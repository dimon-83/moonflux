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
  /// A non-blocking socket had nothing to give. The event loop moves on
  /// to the connections that do have something.
  WouldBlock
} derive(Debug, Eq)

///|
pub impl Show for NetError with fn output(self, logger) {
  match self {
    BadAddress(msg) => logger.write_string("BadAddress(\{msg})")
    Io(code, op) => logger.write_string("Io(errno=\{code}, op=\{op})")
    ConnectionClosed => logger.write_string("ConnectionClosed")
    TimedOut => logger.write_string("TimedOut")
    WouldBlock => logger.write_string("WouldBlock")
  }
}

///|
/// The shim's dedicated timeout code (see net_shim.c): a socket
/// deadline that expired, not a failure.
const NET_TIMEOUT_CODE : Int = 9999

///|
/// The shim's "nothing to read right now" code: the socket is
/// non-blocking and would block. Distinct from an error and from a
/// clean EOF, which is what lets an event loop make progress on other
/// connections instead of waiting.
const NET_WOULD_BLOCK_CODE : Int = 9998

///|
/// Wraps a raw FFI result: negative means -errno, except the shim's
/// timeout sentinel, which becomes `TimedOut`.
fn io_result(code : Int, op : String) -> Result[Int, NetError] {
  if code < 0 {
    if -code == NET_TIMEOUT_CODE {
      Err(TimedOut)
    } else if -code == NET_WOULD_BLOCK_CODE {
      Err(WouldBlock)
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
    if -n == NET_WOULD_BLOCK_CODE {
      return Err(WouldBlock)
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

///|
/// Switches the socket between blocking and non-blocking mode. The
/// event loop needs non-blocking: it must never wait on one connection
/// while others have data.
pub fn TcpStream::set_nonblocking(
  self : TcpStream,
  enabled : Bool,
) -> Result[Unit, NetError] {
  match
    io_result(
      net_set_nonblocking(self.fd, if enabled { 1 } else { 0 }),
      "fcntl",
    ) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Reads whatever is available on a non-blocking socket: `Ok(0)` means
/// the peer closed, `Err(WouldBlock)` means nothing right now, and a
/// positive count is data. The three cases must stay distinguishable —
/// the event loop's correctness depends on it.
pub fn TcpStream::recv_some(
  self : TcpStream,
  buf : FixedArray[Byte],
  len : Int,
) -> Result[Int, NetError] {
  if len < 0 || len > buf.length() {
    return Err(BadAddress("recv bounds"))
  }
  let n = net_recv_some(self.fd, buf, len)
  if n < 0 {
    if -n == NET_WOULD_BLOCK_CODE {
      return Err(WouldBlock)
    }
    return Err(Io(-n, "recv"))
  }
  Ok(n)
}

///|
/// Polls sockets for readability with a timeout, returning the indexes
/// that are ready (in the order given). This is the whole basis of
/// serving many connections from one thread: wait on all of them, then
/// advance only the ones that have something.
///
/// Sockets that closed or errored also report ready, so the caller
/// discovers EOF by reading rather than by missing it forever.
pub fn poll_readable(
  streams : Array[TcpStream],
  timeout_ms : Int,
) -> Result[Array[Int], NetError] {
  let count = streams.length()
  if count == 0 {
    return Ok([])
  }
  if count > 128 {
    return Err(BadAddress("poll supports at most 128 sockets"))
  }
  let fds : FixedArray[Int] = FixedArray::make(count, 0)
  for i in 0..<count {
    fds[i] = streams[i].raw_fd()
  }
  let ready : FixedArray[Int] = FixedArray::make(count, 0)
  let hits = net_poll_readable(fds, count, timeout_ms, ready)
  if hits < 0 {
    return Err(Io(-hits, "poll"))
  }
  let out : Array[Int] = []
  for i in 0..<count {
    if ready[i] != 0 {
      out.push(i)
    }
  }
  Ok(out)
}

///|
/// Writes as much as the socket will take right now. `Ok(0)` means the
/// send buffer is full — the caller keeps the rest and tries again on
/// the next pass, which is how one slow reader cannot stall the loop.
pub fn TcpStream::send_some(
  self : TcpStream,
  data : Bytes,
) -> Result[Int, NetError] {
  if data.length() == 0 {
    return Ok(0)
  }
  let n = net_send_some(self.fd, data, data.length())
  if n < 0 {
    if -n == NET_WOULD_BLOCK_CODE {
      return Ok(0)
    }
    return Err(Io(-n, "send"))
  }
  Ok(n)
}

// ---------------------------------------------------------------------
// The stream interface (P12).
//
// The event loop and the replication link need "a connected byte
// stream", not "a socket": with TLS in the picture there are two kinds,
// and binding those layers to the concrete socket type would push TLS
// through every one of them. An interface of function fields is the same
// shape the client kernel already injects for its own transport — one
// idea, used twice.

///|
/// A connected stream: what the event loop, the replication link and the
/// control loops actually use. `pending` exists for TLS: decrypted bytes
/// may be buffered in the session while the socket itself has nothing to
/// read, and a poll loop that only watches the socket would sleep
/// through them.
pub(all) struct Stream {
  /// The socket under this stream, for polling.
  fd : () -> Int
  /// Reads what is available: `Ok(0)` = peer closed, `WouldBlock` =
  /// nothing now, positive = bytes. The three must stay distinguishable.
  recv_some : (FixedArray[Byte], Int) -> Result[Int, NetError]
  /// Writes what the socket accepts; a short write is normal.
  send_some : (Bytes) -> Result[Int, NetError]
  /// Bytes already buffered *inside* this stream (0 for plain sockets).
  pending : () -> Int
  /// Non-blocking is the event loop's requirement, not a preference.
  set_nonblocking : (Bool) -> Result[Unit, NetError]
  close : () -> Unit
}

///|
/// The plain-socket constructor: a TCP stream is already a stream.
pub fn TcpStream::stream(self : TcpStream) -> Stream {
  Stream::{
    fd: fn() { self.raw_fd() },
    recv_some: fn(buf, len) { self.recv_some(buf, len) },
    send_some: fn(bytes) { self.send_some(bytes) },
    pending: fn() { 0 },
    set_nonblocking: fn(enabled) { self.set_nonblocking(enabled) },
    close: fn() { let _ = self.close() },
  }
}

///|
/// Polls raw descriptors for readability (or writability, which is what
/// a TLS handshake waiting on `WANT_WRITE` needs). The interface's `fd`
/// is what feeds this: the poller does not need to know what kind of
/// stream is on the other end.
pub fn poll_fds(
  fds : Array[Int],
  timeout_ms : Int,
  want_write : Bool,
) -> Result[Array[Int], NetError] {
  let count = fds.length()
  if count == 0 {
    return Ok([])
  }
  if count > 128 {
    return Err(BadAddress("poll supports at most 128 descriptors"))
  }
  let raw : FixedArray[Int] = FixedArray::make(count, 0)
  for i in 0..<count {
    raw[i] = fds[i]
  }
  let ready : FixedArray[Int] = FixedArray::make(count, 0)
  let hits = if want_write {
    net_poll_writable(raw, count, timeout_ms, ready)
  } else {
    net_poll_readable(raw, count, timeout_ms, ready)
  }
  if hits < 0 {
    return Err(Io(-hits, "poll"))
  }
  let out : Array[Int] = []
  for i in 0..<hits {
    out.push(ready[i])
  }
  Ok(out)
}
