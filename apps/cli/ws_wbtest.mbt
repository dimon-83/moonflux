// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the WebSocket transport. The handshake vector is
// RFC 6455 §1.3's own example, so a wrong SHA-1 or Base64 cannot pass
// by agreeing with itself.

///|
test "sha1 matches the FIPS and RFC vectors" {
  // SHA-1("abc")
  let abc = @utf8.encode("abc")
  assert_eq(
    @codec.hex_encode(sha1(abc)),
    "a9993e364706816aba3e25717850c26c9cd0d89d",
  )
  // the empty string
  assert_eq(
    @codec.hex_encode(sha1(b"")),
    "da39a3ee5e6b4b0d3255bfef95601890afd80709",
  )
  // a message spanning more than one 64-byte block
  let long = @utf8.encode(
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
  )
  assert_eq(
    @codec.hex_encode(sha1(long)),
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
  )
}

///|
test "the websocket accept key matches RFC 6455's worked example" {
  // "dGhlIHNhbXBsZSBub25jZQ==" must yield
  // "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" (RFC 6455 §1.3)
  assert_eq(
    ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
  )
}

///|
test "base64 pads correctly" {
  assert_eq(base64_encode(b""), "")
  assert_eq(base64_encode(@utf8.encode("f")), "Zg==")
  assert_eq(base64_encode(@utf8.encode("fo")), "Zm8=")
  assert_eq(base64_encode(@utf8.encode("foo")), "Zm9v")
  assert_eq(base64_encode(@utf8.encode("foob")), "Zm9vYg==")
  assert_eq(base64_encode(@utf8.encode("fooba")), "Zm9vYmE=")
  assert_eq(base64_encode(@utf8.encode("foobar")), "Zm9vYmFy")
}

///|
test "the HTTP sniffer separates a browser from a CLI" {
  assert_true(looks_like_http(b"GET /x HTTP/1.1\r\n"))
  // a frame-carrying CLI starts with MFS, not with a verb
  assert_true(!looks_like_http(b"MFS\x02"))
  assert_true(!looks_like_http(b"MF"))
}

///|
test "websocket frames round trip through a masked client frame" {
  let (client_conn, server_conn) = @client.Conn::memory_pair()
  // a client must mask; build one by hand (the test is the only client
  // here, and the server must see a masked frame to accept it)
  let payload = @utf8.encode("hello")
  let out = @buffer.Buffer::Buffer()
  out.write_byte(b'\x82') // FIN + binary
  out.write_byte((0x80 | payload.length()).to_byte()) // masked, len 5
  let mask : FixedArray[Byte] = [b'\x01', b'\x02', b'\x03', b'\x04']
  for i in 0..<4 {
    out.write_byte(mask[i])
  }
  for i in 0..<payload.length() {
    out.write_byte((payload[i].to_uint() ^ mask[i % 4].to_uint()).to_byte())
  }
  match (client_conn.send)(out.to_bytes()) {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match ws_read_frame(server_conn) {
    Ok(frame) => {
      assert_eq(frame.opcode, WS_BINARY)
      assert_eq(
        @utf8.decode_lossy(frame.payload[0:frame.payload.length()]),
        "hello",
      )
    }
    Err(e) => abort("read frame: \{e}")
  }
}

///|
test "the transport unwraps frames and answers pings" {
  let (client_conn, server_conn) = @client.Conn::memory_pair()
  let transport = ws_transport(server_conn)
  // a ping followed by a data frame: the layer above sees only the data
  write_masked_frame(client_conn, WS_PING, @utf8.encode("beat"))
  write_masked_frame(client_conn, WS_BINARY, @utf8.encode("MFSpayload"))
  match (transport.recv_exact)(10) {
    Ok(bytes) =>
      assert_eq(@utf8.decode_lossy(bytes[0:bytes.length()]), "MFSpayload")
    Err(e) => abort("recv: \{e}")
  }
  // the pong comes back as an *unmasked* frame — server frames must
  // not be masked — so it is parsed here rather than with the
  // server-side reader (which insists on masking, by design)
  let (opcode, payload) = read_server_frame(client_conn)
  assert_eq(opcode, WS_PONG)
  assert_eq(@utf8.decode_lossy(payload[0:payload.length()]), "beat")
}

///|
test "an unmasked client frame is refused" {
  let (client_conn, server_conn) = @client.Conn::memory_pair()
  // FIN + binary, unmasked, length 2, no mask key
  match (client_conn.send)(b"\x82\x02hi") {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match ws_read_frame(server_conn) {
    Err(msg) => assert_true(msg.contains("masked"))
    Ok(_) => abort("an unmasked client frame must be refused")
  }
}

///|
/// Writes a masked client frame (what a browser would send).
fn write_masked_frame(
  conn : @client.Conn,
  opcode : Int,
  payload : Bytes,
) -> Unit {
  let out = @buffer.Buffer::Buffer()
  out.write_byte((0x80 | opcode).to_byte())
  out.write_byte((0x80 | payload.length()).to_byte())
  let mask : FixedArray[Byte] = [b'\x0A', b'\x0B', b'\x0C', b'\x0D']
  for i in 0..<4 {
    out.write_byte(mask[i])
  }
  for i in 0..<payload.length() {
    out.write_byte((payload[i].to_uint() ^ mask[i % 4].to_uint()).to_byte())
  }
  match (conn.send)(out.to_bytes()) {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
}

///|
/// Reads one frame from a server (unmasked is expected here — the
/// masking rule applies to clients).
fn read_server_frame(conn : @client.Conn) -> (Int, Bytes) {
  let header = match (conn.recv_exact)(2) {
    Ok(header) => header
    Err(e) => abort("header: \{e}")
  }
  let opcode = (header[0] & 0x0F).to_int()
  let masked = (header[1] & 0x80) != b'\x00'
  if masked {
    abort("server frames must not be masked")
  }
  let len = (header[1] & 0x7F).to_int()
  let payload = if len > 0 {
    match (conn.recv_exact)(len) {
      Ok(payload) => payload
      Err(e) => abort("payload: \{e}")
    }
  } else {
    b""
  }
  (opcode, payload)
}
