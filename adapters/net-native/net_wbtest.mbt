// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for adapters/net-native — in-process smoke tests
// over an AF_UNIX socketpair (no concurrency needed). Full TCP
// round trips live in the E2E scripts; single-flight loopback TCP
// is covered where a peer process exists.

///|
test "socketpair send and recv round trip" {
  let pair = match socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  let (a, b) = pair
  assert_eq(a.send_all(b"ping-pong"), Ok(9))
  let buf : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  assert_eq(b.recv(buf, 16), Ok(9))
  let back : Array[Byte] = []
  for i in 0..<9 {
    back.push(buf[i])
  }
  assert_eq(Bytes::from_array(back[:]), b"ping-pong")
  assert_eq(a.close(), Ok(()))
  assert_eq(b.close(), Ok(()))
}

///|
test "recv returns zero on clean end of stream" {
  let pair = match socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  let (a, b) = pair
  assert_eq(a.close(), Ok(()))
  let buf : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  assert_eq(b.recv(buf, 4), Ok(0))
  assert_eq(b.close(), Ok(()))
}

///|
test "port validation rejects nonsense before any syscall" {
  match TcpStream::connect("localhost", 0) {
    Err(BadAddress(_)) => ()
    Err(_) => abort("expected BadAddress")
    Ok(_) => abort("expected BadAddress, got a connection")
  }
  match TcpListener::bind_listen("localhost", 70000) {
    Err(BadAddress(_)) => ()
    Err(_) => abort("expected BadAddress")
    Ok(_) => abort("expected BadAddress, got a listener")
  }
}

///|
test "bind listen on ephemeral port reports the assigned port" {
  let listener = match TcpListener::bind_listen("127.0.0.1", 0) {
    Ok(l) => l
    Err(e) => abort("bind: \{e}")
  }
  let port = match listener.local_port() {
    Ok(port) => port
    Err(e) => abort("getsockname: \{e}")
  }
  assert_true(port > 0)
  assert_eq(listener.close(), Ok(()))
}

///|
test "a listener accept times out instead of blocking forever" {
  let listener = match TcpListener::bind_listen("127.0.0.1", 0) {
    Ok(l) => l
    Err(e) => abort("bind: \{e}")
  }
  match listener.set_accept_timeout_ms(150) {
    Ok(_) => ()
    Err(e) => abort("set timeout: \{e}")
  }
  // nobody connects: the call must return TimedOut, not hang (the
  // test itself would hang if the timeout were not honoured)
  match listener.accept() {
    Err(TimedOut) => ()
    Err(e) => abort("expected TimedOut, got \{e}")
    Ok(_) => abort("expected no connection")
  }
  // and a real connection still comes through afterwards
  let port = match listener.local_port() {
    Ok(port) => port
    Err(e) => abort("local port: \{e}")
  }
  let stream = match TcpStream::connect("127.0.0.1", port) {
    Ok(s) => s
    Err(e) => abort("connect: \{e}")
  }
  match listener.accept() {
    Ok(accepted) => {
      let _ = accepted.close()
    }
    Err(e) => abort("accept after timeout: \{e}")
  }
  let _ = stream.close()
  let _ = listener.close()
}

///|
test "recv honours the socket timeout" {
  let (a, b) = match socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  match a.set_recv_timeout_ms(120) {
    Ok(_) => ()
    Err(e) => abort("set timeout: \{e}")
  }
  let buf : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  match a.recv(buf, 16) {
    Err(TimedOut) => ()
    Err(e) => abort("expected TimedOut, got \{e}")
    Ok(n) => abort("expected no data, got \{n}")
  }
  // data sent after the deadline still arrives on the next call
  match b.send_all(b"ping") {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match a.recv(buf, 16) {
    Ok(n) => assert_eq(n, 4)
    Err(e) => abort("recv after timeout: \{e}")
  }
  let _ = a.close()
  let _ = b.close()
}
