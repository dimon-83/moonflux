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
