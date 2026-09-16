// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for apps/client — protocol codec plus full SDK flows
// over an in-process socketpair. The scripted server pre-seeds replies
// into the socketpair buffer, so request/response sequences run
// without threads.

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 5L,
    key: b"",
    value: @utf8.encode(value[0:value.length()]),
    headers: [],
  }
}

///|
fn seed_welcome(server : Conn) -> Unit {
  match
    server.send_frame(Frame::{
      cmd: CMD_WELCOME,
      rid: 0,
      payload: encode_hello(1, 0),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed welcome: \{e}")
  }
}

///|
test "frame codec round trip" {
  let frame = Frame::{ cmd: CMD_PRODUCE, rid: 42, payload: b"payload" }
  let encoded = encode_frame(frame)
  match decode_header(encoded[0:13].to_owned()) {
    Ok((cmd, rid, len)) => {
      assert_eq(cmd, CMD_PRODUCE)
      assert_eq(rid, 42)
      assert_eq(len, 7)
    }
    Err(e) => abort("decode: \{e}")
  }
  // error payload round trip
  let (code, msg) = decode_error(encode_error(ERR_TRANSFORM, "boom"))
  assert_eq(code, ERR_TRANSFORM)
  assert_eq(msg, "boom")
  // version and magic are validated
  let bad_magic = flip_byte(encoded, 0, b'X')
  assert_true(decode_header(bad_magic[0:13].to_owned()) is Err(_))
  let bad_version = flip_byte(encoded, 3, b'\x09')
  assert_true(decode_header(bad_version[0:13].to_owned()) is Err(_))
}

///|
test "producer handshake and send over socketpair" {
  let (client_conn, server_conn) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  // pre-seed the replies the client will read
  seed_welcome(server_conn)
  let producer = match Producer::from_conn(client_conn) {
    Ok(producer) => producer
    Err(e) => abort("handshake: \{e}")
  }
  assert_eq(producer.session_version(), (1, 0))
  // the server side now sees HELLO (written but not yet read)
  let hello = match server_conn.recv_frame() {
    Ok(Some(frame)) => frame
    _ => abort("missing hello")
  }
  assert_eq(hello.cmd, CMD_HELLO)
  assert_eq(hello.rid, 0)
  assert_eq(decode_hello(hello.payload), Ok((1, 0)))
  // seed the produce reply (rid 1), then have the client send
  let reply_payload = Buffer::Buffer()
  reply_payload.write_int64_be(10L)
  reply_payload.write_uint_be(2U)
  match
    server_conn.send_frame(Frame::{
      cmd: CMD_OK,
      rid: 1,
      payload: reply_payload.to_bytes(),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed produce reply: \{e}")
  }
  match producer.send("events", [rec("a"), rec("b")]) {
    Ok((base, count)) => {
      assert_eq(base, 10L)
      assert_eq(count, 2)
    }
    Err(e) => abort("send: \{e}")
  }
  // the server side sees the produce frame and can decode the batch
  let produce = match server_conn.recv_frame() {
    Ok(Some(frame)) => frame
    _ => abort("missing produce")
  }
  assert_eq(produce.cmd, CMD_PRODUCE)
  assert_eq(produce.rid, 1)
  let reader = @codec.Reader::new(produce.payload)
  let topic_len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(_) => abort("bad topic")
  }
  let topic = match reader.read_bytes(topic_len) {
    Ok(topic) => @utf8.decode_lossy(topic[0:topic.length()])
    Err(_) => abort("bad topic")
  }
  assert_eq(topic, "events")
  let frame_bytes = match reader.read_bytes(reader.remaining()) {
    Ok(frame_bytes) => frame_bytes
    Err(_) => abort("bad batch")
  }
  match @protocol.decode_frame_strict(frame_bytes) {
    Ok(batch) => assert_eq(batch.records.length(), 2)
    Err(e) => abort("batch: \{e}")
  }
  producer.close()
}

///|
test "handshake rejection surfaces the server error code" {
  let (client_conn, server_conn) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  // server rejects an old client: major version mismatch
  match
    server_conn.send_frame(Frame::{
      cmd: CMD_ERR,
      rid: 0,
      payload: encode_error(ERR_UNSUPPORTED_VERSION, "server speaks major 1"),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed err: \{e}")
  }
  match Producer::from_conn(client_conn) {
    Err(Server(code, msg)) => {
      assert_eq(code, ERR_UNSUPPORTED_VERSION)
      assert_true(msg.contains("major 1"))
    }
    Err(e) => abort("expected Server error, got \{e}")
    Ok(_) => abort("handshake must fail")
  }
}

///|
test "request id echo is enforced" {
  let (client_conn, server_conn) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  seed_welcome(server_conn)
  let producer = match Producer::from_conn(client_conn) {
    Ok(producer) => producer
    Err(e) => abort("handshake: \{e}")
  }
  // reply echoes the wrong rid: the client must refuse it
  match
    server_conn.send_frame(Frame::{ cmd: CMD_OK, rid: 99, payload: b"\x00" }) {
    Ok(_) => ()
    Err(e) => abort("seed reply: \{e}")
  }
  match producer.send("t", [rec("x")]) {
    Err(Protocol(msg)) => assert_true(msg.contains("99"))
    Err(e) => abort("expected Protocol error, got \{e}")
    Ok(_) => abort("mismatched rid must fail")
  }
}

///|
test "consumer fetch decodes offsets from batch frames" {
  let (client_conn, server_conn) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  seed_welcome(server_conn)
  let consumer = match Consumer::from_conn(client_conn) {
    Ok(consumer) => consumer
    Err(e) => abort("handshake: \{e}")
  }
  // seed a fetch reply: one batch frame at base offset 7 with 2 records
  let batch = @protocol.encode_frame(7L, [rec("m"), rec("n")])
  let payload = Buffer::Buffer()
  payload.write_uint_be(1U)
  payload.write_uint_be(batch.length().reinterpret_as_uint())
  payload.write_bytes(batch[0:batch.length()])
  match
    server_conn.send_frame(Frame::{
      cmd: CMD_OK,
      rid: 1,
      payload: payload.to_bytes(),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed fetch reply: \{e}")
  }
  match consumer.fetch("events", 7L, 100) {
    Ok(entries) => {
      assert_eq(entries.length(), 2)
      assert_eq(entries[0].offset, 7L)
      assert_eq(entries[1].offset, 8L)
      assert_eq(entries[0].record, rec("m"))
      assert_eq(entries[1].record, rec("n"))
    }
    Err(e) => abort("fetch: \{e}")
  }
  consumer.close()
}

///|
test "server-side first read distinguishes v1 peers and garbage" {
  let (peer_conn, server_conn) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  // a v1-shaped header (correct magic, old version byte)
  let v1_header = b"MFS\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  match (peer_conn.send)(v1_header) {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match server_conn.recv_first() {
    WrongVersion(v) => assert_eq(v, 1)
    _ => abort("expected WrongVersion(1)")
  }
  // garbage that is not even the right magic
  let (peer2, server2) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  match (peer2.send)(b"NOISE............") {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match server2.recv_first() {
    Garbage(msg) => assert_true(msg.contains("magic"))
    _ => abort("expected Garbage")
  }
  // a proper v2 frame passes through untouched
  let (peer3, server3) = match Conn::socketpair() {
    Ok(pair) => pair
    Err(e) => abort("socketpair: \{e}")
  }
  match
    peer3.send_frame(Frame::{
      cmd: CMD_HELLO,
      rid: 0,
      payload: encode_hello(1, 0),
    }) {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match server3.recv_first() {
    Got(frame) => assert_eq(frame.cmd, CMD_HELLO)
    _ => abort("expected Got(HELLO)")
  }
}

///|
fn flip_byte(data : Bytes, index : Int, replacement : Byte) -> Bytes {
  let out = Buffer::Buffer()
  for i in 0..<data.length() {
    out.write_byte(if i == index { replacement } else { data[i] })
  }
  out.to_bytes()
}

///|
test "node record round trips and rejects malformed input" {
  let record = NodeRecord::{
    id: "spu-a",
    role: Spu,
    address: "127.0.0.1:19001",
    leo: 42L,
  }
  let bytes = encode_node(record)
  match decode_node(bytes) {
    Ok(decoded) => assert_eq(decoded, record)
    Err(e) => abort("decode: \{e}")
  }
  // deterministic encoding
  assert_eq(encode_node(record), bytes)
  // an unknown role name is refused, not defaulted to a data node
  // (hand-built: id="x", role="node", address="a:1", leo=0)
  assert_true(decode_node(b"\x01x\x04node\x03a:1\x00") is Err(_))
  let zero_id = NodeRecord::{ id: "", role: Sc, address: "a:1", leo: 0L }
  assert_true(decode_node(encode_node(zero_id)) is Err(_))
  let empty_addr = NodeRecord::{ id: "x", role: Sc, address: "", leo: 0L }
  assert_true(decode_node(encode_node(empty_addr)) is Err(_))
  // truncated payloads never yield a partial record
  assert_true(decode_node(b"\x03spu") is Err(_))
  assert_true(decode_node(b"") is Err(_))
}

///|
test "the control plane's node table round trips" {
  let nodes = [
    NodeRecord::{ id: "spu-a", role: Spu, address: "127.0.0.1:19001", leo: 7L },
    NodeRecord::{ id: "spu-b", role: Spu, address: "127.0.0.1:19002", leo: 0L },
  ]
  match decode_nodes(encode_nodes(nodes)) {
    Ok(decoded) => assert_eq(decoded, nodes)
    Err(e) => abort("decode nodes: \{e}")
  }
  match decode_nodes(encode_nodes([])) {
    Ok(decoded) => assert_eq(decoded.length(), 0)
    Err(e) => abort("empty table: \{e}")
  }
  // a corrupt entry fails the whole table rather than being skipped
  let truncated = b"\x02\x05\x01a"
  assert_true(decode_nodes(truncated) is Err(_))
}
