// SPDX-License-Identifier: Apache-2.0
// serve: single-process, single-connection-at-a-time broker holding
// topic logs under the data dir. P1 adds multiplexing and the fully
// versioned protocol service; P0 keeps the loop deliberately simple.

///|
fn cmd_serve(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let addr = flags.require("listen")
  let (host, port) = parse_listen_addr(addr)
  let listener = match @net.TcpListener::bind_listen(host, port) {
    Ok(l) => l
    Err(e) => fail("bind \{host}:\{port}: \{e}")
  }
  let actual = match listener.local_port() {
    Ok(port) => port
    Err(_) => port
  }
  println(
    "moonflux serve listening on \{host}:\{actual} (data dir \{data_dir})",
  )
  let rules = RuleState::new()
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_connection(stream, data_dir, rules)
        let _ = stream.close()
      }
      Err(e) => fail("accept: \{e}")
    }
  }
}

///|
/// Handles one connection: v2 handshake first, then sequential
/// request frames until the peer closes. One reply frame per request
/// with the request id echoed.
fn handle_connection(
  stream : @net.TcpStream,
  data_dir : String,
  rules : RuleState,
) -> Unit {
  let conn = @client.Conn::from_stream(stream)
  // handshake: HELLO must be the first frame; the major version
  // decides whether the session may proceed
  let hello = match conn.recv_first() {
    @client.Got(frame) => frame
    @client.Eof => return
    @client.WrongVersion(version) => {
      // a v1-era peer gets a structured rejection, never a silent drop
      let _ = conn.send_frame(@client.Frame::{
        cmd: @client.CMD_ERR,
        rid: 0,
        payload: @client.encode_error(
          @client.ERR_UNSUPPORTED_VERSION,
          "server speaks frame version \{@client.PROTOCOL_VERSION}; peer sent \{version}",
        ),
      })
      return
    }
    @client.Garbage(msg) => {
      let _ = conn.send_frame(@client.Frame::{
        cmd: @client.CMD_ERR,
        rid: 0,
        payload: @client.encode_error(@client.ERR_BAD_PAYLOAD, msg),
      })
      return
    }
  }
  if hello.cmd != @client.CMD_HELLO {
    let _ = conn.send_frame(@client.Frame::{
      cmd: @client.CMD_ERR,
      rid: hello.rid,
      payload: @client.encode_error(
        @client.ERR_SEQUENCE,
        "handshake required: send HELLO first",
      ),
    })
    return
  }
  let (major, minor) = match @client.decode_hello(hello.payload) {
    Ok(parts) => parts
    Err(e) => {
      let _ = conn.send_frame(@client.Frame::{
        cmd: @client.CMD_ERR,
        rid: hello.rid,
        payload: @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
      })
      return
    }
  }
  if major != 1 {
    let _ = conn.send_frame(@client.Frame::{
      cmd: @client.CMD_ERR,
      rid: hello.rid,
      payload: @client.encode_error(
        @client.ERR_UNSUPPORTED_VERSION,
        "server speaks major version 1 (frames v2); client sent \{major}",
      ),
    })
    return
  }
  let _ = conn.send_frame(@client.Frame::{
    cmd: @client.CMD_WELCOME,
    rid: hello.rid,
    payload: @client.encode_hello(1, 0),
  })
  let _ = minor
  while true {
    let frame = match conn.recv_frame() {
      Ok(Some(frame)) => frame
      Ok(None) => return // peer closed
      Err(_) => return
    }
    let reply = match frame.cmd {
      @client.CMD_PRODUCE => dispatch_produce(frame.payload, data_dir)
      @client.CMD_FETCH => {
        // hot-reload checkpoint: picks up a freshly applied spec here
        rules.sync(data_dir)
        dispatch_fetch(frame.payload, data_dir, rules)
      }
      @client.CMD_FETCH_COMMITTED => {
        rules.sync(data_dir)
        // a standalone broker has one replica, so its committed prefix
        // is its whole log; the topic is parsed inside the handler, so
        // the watermarks are read from the request's topic here
        match committed_watermarks_for(frame.payload, data_dir) {
          Ok((hw, leo)) =>
            dispatch_fetch_committed(frame.payload, data_dir, rules, hw, leo)
          Err(e) => err_reply(@client.ERR_BAD_PAYLOAD, e)
        }
      }
      other =>
        (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_UNKNOWN_COMMAND,
            "unknown command \{other}",
          ),
        )
    }
    match
      conn.send_frame(@client.Frame::{
        cmd: reply.0,
        rid: frame.rid,
        payload: reply.1,
      }) {
      Ok(_) => ()
      Err(_) => return
    }
  }
}

///|
fn reply(cmd : Int, payload : Bytes) -> (Int, Bytes) {
  (cmd, payload)
}

///|
/// Structured error reply with a stable code (client-visible).
fn err_reply(code : Int, msg : String) -> (Int, Bytes) {
  reply(@client.CMD_ERR, @client.encode_error(code, msg))
}

///|
fn dispatch_produce(payload : Bytes, data_dir : String) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let rest = reader.remaining()
  let frame = match reader.read_bytes(rest) {
    Ok(frame) => frame
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad produce payload")
  }
  let records = match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad batch: \{e}")
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let base = match log.append(records) {
    Ok(base) => base
    Err(e) => return err_reply(@client.ERR_STORAGE, "append: \{e}")
  }
  let out = Buffer::Buffer()
  out.write_int64_be(base)
  out.write_uint_be(records.length().reinterpret_as_uint())
  reply(@client.CMD_OK, out.to_bytes())
}

///|
fn dispatch_fetch(
  payload : Bytes,
  data_dir : String,
  rules : RuleState,
) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let from = match reader.read_i64_be() {
    Ok(from) => from
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad fetch payload")
  }
  let max = match reader.read_u32_be() {
    Ok(max) => max.reinterpret_as_int()
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad fetch payload")
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let entries = match log.read(from, max) {
    Ok(entries) => entries
    Err(e) => return err_reply(@client.ERR_STORAGE, "read: \{e}")
  }
  // one batch frame carries the whole window; the client derives
  // per-record offsets from its base offset. The dynamic rule chain
  // (mbel transforms) runs here, on the consumption path.
  let records : Array[@protocol.Record] = []
  for entry in entries {
    match apply_nodes(rules.chain, [entry.record]) {
      Ok(out_one) =>
        for r in out_one {
          records.push(r)
        }
      Err(e) => return err_reply(@client.ERR_TRANSFORM, "transform: \{e}")
    }
  }
  let base : Int64 = if records.length() > 0 { entries[0].offset } else { from }
  let frame = @protocol.encode_frame(base, records)
  let out = Buffer::Buffer()
  out.write_uint_be(1U)
  out.write_uint_be(frame.length().reinterpret_as_uint())
  out.write_bytes(frame[0:frame.length()])
  reply(@client.CMD_OK, out.to_bytes())
}

///|
/// Reads the topic out of a fetch payload (used to look up watermarks
/// before dispatching). Kept separate so the dispatch functions can
/// stay symmetric.
fn committed_watermarks_for(
  payload : Bytes,
  data_dir : String,
) -> Result[(Int64, Int64), String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  single_node_watermarks(data_dir, topic)
}

///|
/// A committed read: the same window, but bounded by the partition's
/// high watermark instead of the log end, and the reply carries the
/// watermarks that bounded it. Reading at exactly the watermark is
/// legal and empty (the caller is caught up); reading past it is a
/// structured refusal, because "not replicated yet" must never be
/// mistaken for "no data" (core/replica.check_read owns that rule).
fn dispatch_fetch_committed(
  payload : Bytes,
  data_dir : String,
  rules : RuleState,
  high_watermark : Int64,
  log_end_offset : Int64,
) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let from = match reader.read_i64_be() {
    Ok(from) => from
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad fetch payload")
  }
  let max = match reader.read_u32_be() {
    Ok(max) => max.reinterpret_as_int()
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad fetch payload")
  }
  let info = @replica.OffsetInfo::{ high_watermark, log_end_offset }
  match @replica.check_read(info, Committed, from, max) {
    Ok(_) => ()
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, "\{e}")
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  // the window itself is clamped by the watermark: the leader may hold
  // more, and the committed reader must not see it
  let window_end = if high_watermark < log.high_watermark() {
    high_watermark
  } else {
    log.high_watermark()
  }
  let available = if from >= window_end {
    0
  } else {
    (window_end - from).to_int()
  }
  let take = if max < available { max } else { available }
  let entries = match log.read(from, take) {
    Ok(entries) => entries
    Err(e) => return err_reply(@client.ERR_STORAGE, "read: \{e}")
  }
  let records : Array[@protocol.Record] = []
  for entry in entries {
    match apply_nodes(rules.chain, [entry.record]) {
      Ok(out_one) =>
        for r in out_one {
          records.push(r)
        }
      Err(e) => return err_reply(@client.ERR_TRANSFORM, "transform: \{e}")
    }
  }
  let base : Int64 = if records.length() > 0 { entries[0].offset } else { from }
  let frame = @protocol.encode_frame(base, records)
  let response = @client.SyncResponse::{
    base_offset: base,
    record_count: records.length(),
    high_watermark,
    log_end_offset,
    frames: frame,
  }
  reply(@client.CMD_OK, @client.encode_sync_response(response))
}

///|
/// The watermark pair a plain (single-node) broker serves: with one
/// replica the committed prefix IS the log end — the partition is
/// trivially replicated the moment it is written, which is why a
/// standalone `serve` answers both modes identically.
fn single_node_watermarks(
  data_dir : String,
  topic : String,
) -> Result[(Int64, Int64), String] {
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  let leo = log.high_watermark()
  Ok((leo, leo))
}

///|
fn read_topic_name(reader : @codec.Reader) -> Result[String, String] {
  let len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(_) => return Err("bad topic name")
  }
  if len > 128 {
    return Err("topic name too long")
  }
  let bytes = match reader.read_bytes(len) {
    Ok(bytes) => bytes
    Err(_) => return Err("bad topic name")
  }
  let topic = @utf8.decode_lossy(bytes[0:bytes.length()])
  if not(valid_topic(topic)) {
    return Err("invalid topic name '\{topic}'")
  }
  Ok(topic)
}
