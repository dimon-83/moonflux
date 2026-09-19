// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/client — protocol codec plus full session
// flows over the in-memory transport pair. The scripted server
// pre-seeds replies, so request/response sequences run without
// threads — and, because the transport is memory rather than sockets,
// the same tests run on every backend the kernel compiles for.

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
test "producer handshake and send over the in-memory transport" {
  let (client_conn, server_conn) = Conn::memory_pair()
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
  let (client_conn, server_conn) = Conn::memory_pair()
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
  let (client_conn, server_conn) = Conn::memory_pair()
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
  let (client_conn, server_conn) = Conn::memory_pair()
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
  let (peer_conn, server_conn) = Conn::memory_pair()
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
  let (peer2, server2) = Conn::memory_pair()
  match (peer2.send)(b"NOISE............") {
    Ok(_) => ()
    Err(e) => abort("send: \{e}")
  }
  match server2.recv_first() {
    Garbage(msg) => assert_true(msg.contains("magic"))
    _ => abort("expected Garbage")
  }
  // a proper v2 frame passes through untouched
  let (peer3, server3) = Conn::memory_pair()
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

///|
test "replication payloads round trip and reject malformed input" {
  let ref_ = PartitionRef::{ topic: "events", partition: 0 }
  let request = SyncRequest::{ partition: ref_, from: 12L, max_records: 64 }
  match decode_sync_request(encode_sync_request(request)) {
    Ok(decoded) => assert_eq(decoded, request)
    Err(e) => abort("sync request: \{e}")
  }
  // a negative resume offset is refused, not clamped
  assert_true(
    decode_sync_request(
      encode_sync_request(SyncRequest::{
        partition: ref_,
        from: -1L,
        max_records: 8,
      }),
    )
    is Err(_),
  )
  assert_true(
    decode_sync_request(
      encode_sync_request(SyncRequest::{
        partition: ref_,
        from: 0L,
        max_records: 0,
      }),
    )
    is Err(_),
  )
  // topic names go through the same whitelist as everywhere else
  assert_true(
    decode_sync_request(
      encode_sync_request(SyncRequest::{
        partition: PartitionRef::{ topic: "Bad Name", partition: 0 },
        from: 0L,
        max_records: 8,
      }),
    )
    is Err(_),
  )

  let response = SyncResponse::{
    base_offset: 4L,
    record_count: 3,
    high_watermark: 7L,
    log_end_offset: 9L,
    frames: b"\x01\x02\x03",
  }
  match decode_sync_response(encode_sync_response(response)) {
    Ok(decoded) => assert_eq(decoded, response)
    Err(e) => abort("sync response: \{e}")
  }
  // trailing bytes mean the payload is not what it claims to be
  assert_true(
    decode_sync_response(
      b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x00",
    )
    is Err(_),
  )

  let ack = SyncAck::{ partition: ref_, from: "127.0.0.1:1", leo: 7L }
  match decode_sync_ack(encode_sync_ack(ack)) {
    Ok(decoded) => assert_eq(decoded, ack)
    Err(e) => abort("sync ack: \{e}")
  }
  // an ack with no sender cannot be attributed to a replica
  assert_true(
    decode_sync_ack(
      encode_sync_ack(SyncAck::{ partition: ref_, from: "", leo: 1L }),
    )
    is Err(_),
  )
}

///|
test "partition views carry the leader and the replica set" {
  let view = PartitionView::{
    leader: "127.0.0.1:1",
    replicas: ["127.0.0.1:1", "127.0.0.1:2"],
    nominated: "",
  }
  match decode_partition_view(encode_partition_view(view)) {
    Ok(decoded) => assert_eq(decoded, view)
    Err(e) => abort("partition view: \{e}")
  }
  // "no leader yet" is a state, not an error: the replica set may
  // still be known
  let unassigned = PartitionView::{
    leader: "",
    replicas: ["127.0.0.1:1"],
    nominated: "127.0.0.1:1",
  }
  match decode_partition_view(encode_partition_view(unassigned)) {
    Ok(decoded) => {
      assert_eq(decoded.leader, "")
      assert_eq(decoded.replicas.length(), 1)
      // an offer without a leader is exactly the election state
      assert_eq(decoded.nominated, "127.0.0.1:1")
    }
    Err(e) => abort("unassigned view: \{e}")
  }
  // offsets queries answer with a pair
  assert_eq(decode_offset_info(encode_offset_info(3L, 5L)), Ok((3L, 5L)))
  assert_true(decode_offset_info(b"\x00") is Err(_))
}

///|
test "a committed fetch reply carries watermarks and frames" {
  // the server's reply shape for CMD_FETCH_COMMITTED is the sync
  // response, so the consumer can tell what bounded its window
  let (server, client) = Conn::memory_pair()
  // the handshake happens inside from_conn, so its reply must be
  // waiting in the transport buffer first
  seed_welcome(server)
  let consumer = match Consumer::from_conn(client) {
    Ok(consumer) => consumer
    Err(e) => abort("consumer: \{e}")
  }
  let frame = @protocol.encode_frame(2L, [rec("two"), rec("three")])
  let response = SyncResponse::{
    base_offset: 2L,
    record_count: 2,
    high_watermark: 4L,
    log_end_offset: 6L,
    frames: frame,
  }
  match
    server.send_frame(Frame::{
      cmd: CMD_OK,
      rid: 1,
      payload: encode_sync_response(response),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed reply: \{e}")
  }
  match consumer.fetch_committed("events", 2L, 100) {
    Ok((entries, hw, leo)) => {
      assert_eq(entries.length(), 2)
      // offsets come from the frames' base, not from the request
      assert_eq(entries[0].offset, 2L)
      assert_eq(entries[1].offset, 3L)
      assert_eq(hw, 4L)
      assert_eq(leo, 6L)
    }
    Err(e) => abort("fetch_committed: \{e}")
  }
  consumer.close()
}

///|
test "a committed fetch surfaces the server's refusal" {
  let (server, client) = Conn::memory_pair()
  seed_welcome(server)
  let consumer = match Consumer::from_conn(client) {
    Ok(consumer) => consumer
    Err(e) => abort("consumer: \{e}")
  }
  // reading past the watermark is refused by the server; the client
  // must report that as a server error, not as an empty read
  match
    server.send_frame(Frame::{
      cmd: CMD_ERR,
      rid: 1,
      payload: encode_error(
        ERR_BAD_PAYLOAD,
        "read at 9 exceeds Committed limit 4",
      ),
    }) {
    Ok(_) => ()
    Err(e) => abort("seed error: \{e}")
  }
  match consumer.fetch_committed("events", 9L, 10) {
    Err(Server(code, msg)) => {
      assert_eq(code, ERR_BAD_PAYLOAD)
      assert_true(msg.contains("exceeds"))
    }
    Err(e) => abort("expected a server error, got \{e}")
    Ok(_) => abort("expected the read to be refused")
  }
  consumer.close()
}

// ---------------------------------------------------------------------
// Per-partition reports and assignments (P7). The report section is an
// append to a payload whose decoder never insisted on draining the
// reader, which is exactly why it could be added without a version
// bump — these tests pin both directions of that claim.

///|
test "a node record carries per-partition reports, and older readers still read it" {
  let record = NodeRecord::{
    id: "spu-a",
    role: Spu,
    address: "127.0.0.1:19001",
    leo: 42L,
  }
  let reports = [
    PartitionReport::{ topic: "events", partition: 0, leo: 42L },
    PartitionReport::{ topic: "events", partition: 2, leo: 9L },
  ]
  let bytes = encode_node_full(record, reports)
  // the full decoder sees both halves
  match decode_node_full(bytes) {
    Ok(parts) => {
      let (decoded, decoded_reports) = parts
      assert_eq(decoded, record)
      assert_eq(decoded_reports, reports)
    }
    Err(e) => abort("decode full: \{e}")
  }
  // the sectionless decoder reads the same bytes: the tail is ignored,
  // which is what makes the extension compatible in that direction
  match decode_node(bytes) {
    Ok(decoded) => assert_eq(decoded, record)
    Err(e) => abort("decode: \{e}")
  }
  // and a payload without the section decodes as "no reports" rather
  // than as an error — the other direction
  match decode_node_full(encode_node(record)) {
    Ok(parts) => {
      let (_decoded, decoded_reports) = parts
      assert_eq(decoded_reports.length(), 0)
    }
    Err(e) => abort("decode sectionless: \{e}")
  }
  // a truncated report section is an error, never a partial list
  assert_true(
    decode_node_full(bytes[0:bytes.length() - 1].to_owned()) is Err(_),
  )
}

///|
test "assignments round trip and an empty reply means none" {
  let assignments = [
    AssignmentView::{
      topic: "events",
      partition: 0,
      leader: "127.0.0.1:19001",
      replicas: ["127.0.0.1:19001", "127.0.0.1:19002"],
      nominated: "",
    },
    AssignmentView::{
      topic: "events",
      partition: 1,
      leader: "",
      replicas: ["127.0.0.1:19003"],
      nominated: "127.0.0.1:19003",
    },
  ]
  match decode_assignments(encode_assignments(assignments)) {
    Ok(decoded) => assert_eq(decoded, assignments)
    Err(e) => abort("decode assignments: \{e}")
  }
  // the empty payload a control plane with no placements sends
  match decode_assignments(b"") {
    Ok(decoded) => assert_eq(decoded.length(), 0)
    Err(e) => abort("empty assignments: \{e}")
  }
  let bytes = encode_assignments(assignments)
  assert_true(
    decode_assignments(bytes[0:bytes.length() - 2].to_owned()) is Err(_),
  )
}

///|
test "compaction reports survive the wire, and a truncated one does not" {
  let entries = [
    WireCompaction::{
      base: 0L,
      frames_before: 4,
      frames_after: 2,
      dropped_records: 7,
      bytes_before: 512,
      bytes_after: 233,
    },
    WireCompaction::{
      base: 40L,
      frames_before: 1,
      frames_after: 0,
      dropped_records: 3,
      bytes_before: 90,
      bytes_after: 0,
    },
  ]
  match decode_wire_compactions(encode_wire_compactions(entries)) {
    Ok(decoded) => assert_eq(decoded, entries)
    Err(e) => abort("decode compactions: \{e}")
  }
  // an empty report is a valid answer: "nothing was superseded"
  match decode_wire_compactions(encode_wire_compactions([])) {
    Ok(decoded) => assert_eq(decoded.length(), 0)
    Err(e) => abort("empty compactions: \{e}")
  }
  let bytes = encode_wire_compactions(entries)
  assert_true(
    decode_wire_compactions(bytes[0:bytes.length() - 2].to_owned()) is Err(_),
  )
  // trailing bytes are not a longer report: the decoder has one shape
  let padded = encode_wire_compactions(entries)
  let with_trailer = @buffer.Buffer()
  with_trailer.write_bytes(padded)
  with_trailer.write_byte(b'\x00')
  assert_true(decode_wire_compactions(with_trailer.to_bytes()) is Err(_))
}
