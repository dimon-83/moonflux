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
} derive(Debug, Eq)

///|
pub impl Show for NetError with fn output(self, logger) {
  match self {
    BadAddress(msg) => logger.write_string("BadAddress(\{msg})")
    Io(code, op) => logger.write_string("Io(errno=\{code}, op=\{op})")
    ConnectionClosed => logger.write_string("ConnectionClosed")
  }
}

///|
/// Wraps a raw FFI result: negative means -errno.
fn io_result(code : Int, op : String) -> Result[Int, NetError] {
  if code < 0 {
    Err(Io(-code, op))
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
/// A listening TCP socket awaiting `accept`.
pub struct TcpListener {
  fd : Int
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
    return Err(Io(-n, "recv"))
  }
  Ok(n)
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
    Ok(fd) => Ok(TcpListener::{ fd, })
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
/// Blocks until a peer connects; returns the accepted stream.
pub fn TcpListener::accept(self : TcpListener) -> Result[TcpStream, NetError] {
  match io_result(net_accept(self.fd), "accept") {
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
