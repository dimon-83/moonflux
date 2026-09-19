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
  let ws = flags.get("ws") is Some(_)
  if ws {
    note(
      "websocket upgrade accepted on this port: a browser sends HTTP, a CLI sends MFS",
    )
  }
  let rules = RuleState::new()
  // The hub serves every connection from this one thread: poll them all,
  // advance the ones with data, never wait on one while another has work.
  // Before this, the loop handled one connection at a time and a
  // browser's persistent socket starved every other client.
  match listener.set_accept_timeout_ms(HUB_TICK_MS) {
    Ok(_) => ()
    Err(e) => fail("accept timeout: \{e}")
  }
  // TLS is a property of the listener, not of the protocol above it
  // (P12): either every connection on this port is a TLS session, or none
  // is. The flags are read in one place (`tls_listener`) so `serve` and
  // the node processes cannot drift into two readings of the same flags.
  let tls_context = tls_listener(flags)
  let hub = match tls_context {
    None => ConnectionHub::new(listener, HUB_TICK_MS)
    Some(context) => ConnectionHub::new(listener, HUB_TICK_MS).with_tls(context)
  }
  // the credential table, announced at startup so an operator never has
  // to guess which mode this broker is in
  let auth_config = AuthConfig::load(data_dir)
  announce_auth_mode(data_dir, auth_config)
  let handler = HubHandler::{
    on_frame: fn(frame, identity) {
      dispatch_session_frame(frame, data_dir, rules, ws, identity)
    },
    auth: AuthGate::{ config: auth_config },
    on_ready: fn() {
      // hot-reload checkpoint: a freshly applied spec is picked up here,
      // exactly as it was on the single-connection path
      rules.sync(data_dir)
    },
  }
  note("serving connections concurrently (one thread, poll-driven)")
  // storage housekeeping (P8): a standalone broker owns its partitions
  // alone, so its committed prefix is its own log end — the floor for
  // retention is that end, and the policy is off unless an operator
  // asked for it (README 决策 31)
  let mut last_housekeeping : Int64 = -1L
  while true {
    let live = hub.poll_once(handler, fn(kind) {
      if kind == "websocket" {
        note("browser connected over websocket")
      }
    })
    let _ = live
    let now = @env.now().reinterpret_as_int64()
    if last_housekeeping < 0L || now - last_housekeeping >= HOUSEKEEPING_MS {
      last_housekeeping = now
      let topic = applied_topic(data_dir)
      if topic.length() > 0 {
        let floor = match open_topic_log(data_dir, topic) {
          Ok(log) => log.high_watermark()
          Err(_) => 0L
        }
        match retain_partition(data_dir, topic, 0, floor, now) {
          Ok(_) => ()
          Err(e) => note("warning: \{e}")
        }
      }
    }
  }
}

///|
/// How often storage housekeeping runs (retention, age-based rolling).
/// Slower than the hub tick on purpose: these are disk decisions, and
/// once a second is already far more often than a policy needs.
const HOUSEKEEPING_MS : Int64 = 1000L

///|
/// How long the hub waits for activity before looping (its tick, and
/// the listener's accept deadline).
const HUB_TICK_MS : Int = 200

///|
/// One request against a served connection. This is the single-connection
/// path's dispatch, unchanged — the hub decides *when* it runs, not what
/// it does, so both transports keep exactly one implementation of every
/// command.
fn dispatch_session_frame(
  frame : @client.Frame,
  data_dir : String,
  rules : RuleState,
  ws_enabled : Bool,
  identity : @auth.Identity?,
) -> @client.Frame {
  let _ = ws_enabled
  // the permission check is the *dispatcher's*, not each handler's
  // (P12): one place, so a new command cannot slip past it
  match identity {
    Some(identity) =>
      if !@auth.permit(identity.role, frame.cmd) {
        return err_frame(
          frame.rid,
          @client.ERR_FORBIDDEN,
          "\{identity.name} (\{@auth.role_name(identity.role)}) may not issue command \{frame.cmd}",
        )
      }
    None => ()
  }
  match frame.cmd {
    @client.CMD_HELLO => {
      let (major, minor) = match @client.decode_hello(frame.payload) {
        Ok(parts) => parts
        Err(e) => return err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
      let _ = minor
      if major != 1 {
        return err_frame(
          frame.rid,
          @client.ERR_UNSUPPORTED_VERSION,
          "server speaks major version 1 (frames v2); client sent \{major}",
        )
      }
      @client.Frame::{
        cmd: @client.CMD_WELCOME,
        rid: frame.rid,
        payload: @client.encode_hello(1, 0),
      }
    }
    @client.CMD_PRODUCE => {
      let (code, payload) = dispatch_produce(frame.payload, data_dir)
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_FETCH => {
      rules.sync(data_dir)
      let (code, payload) = dispatch_fetch(frame.payload, data_dir, rules)
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_PRODUCE_PARTITION => {
      let (code, payload) = dispatch_produce_partition(frame.payload, data_dir)
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_FETCH_PARTITION => {
      rules.sync(data_dir)
      let (code, payload) = dispatch_fetch_partition(
        frame.payload,
        data_dir,
        rules,
      )
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_APPLY_PIPELINE =>
      match dispatch_apply(frame.payload, data_dir) {
        Ok(summary) => reply_frame(frame.rid, @client.CMD_OK, summary)
        Err((code, message)) => err_frame(frame.rid, code, message)
      }
    @client.CMD_FETCH_COMMITTED => {
      rules.sync(data_dir)
      match committed_watermarks_for(frame.payload, data_dir) {
        Ok((hw, leo)) => {
          let (code, payload) = dispatch_fetch_committed(
            frame.payload,
            data_dir,
            rules,
            hw,
            leo,
          )
          reply_frame(frame.rid, code, payload)
        }
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
    }
    @client.CMD_SEGMENTS => {
      let ref = match @client.decode_partition_ref(frame.payload) {
        Ok(ref) => ref
        Err(e) => return err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
      match segment_view(data_dir, ref) {
        Ok(payload) => reply_frame(frame.rid, @client.CMD_OK, payload)
        Err((code, message)) => err_frame(frame.rid, code, message)
      }
    }
    @client.CMD_COMPACT => {
      // compaction of a partition this broker owns alone: the floor is
      // its own log end, exactly as retention's is here (P14)
      let ref = match @client.decode_partition_ref(frame.payload) {
        Ok(ref) => ref
        Err(e) => return err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
      let floor = match open_partition_log(data_dir, ref.topic, ref.partition) {
        Ok(log) => log.high_watermark()
        Err(e) => return err_frame(frame.rid, @client.ERR_STORAGE, e)
      }
      match
        compact_partition(
          data_dir,
          ref.topic,
          ref.partition,
          floor,
          @env.now().reinterpret_as_int64(),
        ) {
        Ok(report) => {
          let wire : Array[@client.WireCompaction] = []
          for seg in report.rewritten {
            wire.push(@client.WireCompaction::{
              base: seg.base,
              frames_before: seg.frames_before,
              frames_after: seg.frames_after,
              dropped_records: seg.dropped_records,
              bytes_before: seg.bytes_before,
              bytes_after: seg.bytes_after,
            })
          }
          reply_frame(
            frame.rid,
            @client.CMD_OK,
            @client.encode_wire_compactions(wire),
          )
        }
        Err(message) => err_frame(frame.rid, @client.ERR_STORAGE, message)
      }
    }
    // rule assets: a standalone broker owns its own function sets,
    // because it compiles its own applies (P6)
    cmd if is_function_set_command(cmd) =>
      match dispatch_function_set(frame, file_metadata_store(data_dir)) {
        Ok(payload) => reply_frame(frame.rid, @client.CMD_OK, payload)
        Err((code, message)) => err_frame(frame.rid, code, message)
      }
    other =>
      err_frame(
        frame.rid,
        @client.ERR_UNKNOWN_COMMAND,
        "unknown command \{other}",
      )
  }
}

///|
/// The partition's segments, as the wire carries them.
fn segment_view(
  data_dir : String,
  ref : @client.PartitionRef,
) -> Result[Bytes, (Int, String)] {
  let log = match open_partition_log(data_dir, ref.topic, ref.partition) {
    Ok(log) => log
    Err(e) => return Err((@client.ERR_STORAGE, e))
  }
  let wire : Array[@client.WireSegment] = []
  for summary in log.segment_summaries() {
    wire.push(@client.WireSegment::{
      base: summary.base,
      records: summary.records,
      bytes: summary.bytes,
    })
  }
  Ok(@client.encode_wire_segments(wire))
}

///|
fn reply_frame(rid : Int, code : Int, payload : Bytes) -> @client.Frame {
  if code == @client.CMD_OK {
    @client.Frame::{ cmd: @client.CMD_OK, rid, payload }
  } else {
    // the single-connection path answered errors with an ERR frame
    // carrying the code in its payload; keep that shape exactly
    @client.Frame::{ cmd: @client.CMD_ERR, rid, payload }
  }
}

///|
fn err_frame(rid : Int, code : Int, message : String) -> @client.Frame {
  @client.Frame::{
    cmd: @client.CMD_ERR,
    rid,
    payload: @client.encode_error(code, message),
  }
}

///|
/// Sniffs the start of a connection: an HTTP request becomes a
/// WebSocket session, anything else goes to the frame handler with its
/// first bytes restored.
fn serve_websocket_connection(
  conn : @client.Conn,
  data_dir : String,
  rules : RuleState,
) -> Result[Unit, String] {
  let head = match (conn.recv_exact)(4) {
    Ok(head) => head
    Err(e) => return Err(e)
  }
  if looks_like_http(head) {
    match ws_handshake(conn) {
      Ok(_) => ()
      Err(e) => {
        // an HTTP client deserves an HTTP answer: silently dropping
        // a request that reached the right port is the kind of
        // behavior that costs an operator an afternoon
        let body = "not a websocket upgrade: " + e + "\n"
        let response = "HTTP/1.1 400 Bad Request\r\n" +
          "Content-Type: text/plain\r\n" +
          "Content-Length: " +
          body.length().to_string() +
          "\r\n" +
          "Connection: close\r\n\r\n" +
          body
        let bytes = @utf8.encode(response[0:response.length()])
        let _ = (conn.send)(bytes)
        return Err(e)
      }
    }
    let transport = ws_transport(conn)
    handle_connection(transport, data_dir, rules)
    Ok(())
  } else {
    handle_connection(prefixed_transport(head, conn), data_dir, rules)
    Ok(())
  }
}

///|
/// Handles one connection: v2 handshake first, then sequential
/// request frames until the peer closes. One reply frame per request
/// with the request id echoed.
fn handle_connection(
  conn : @client.Conn,
  data_dir : String,
  rules : RuleState,
) -> Unit {
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
      @client.CMD_APPLY_PIPELINE =>
        match dispatch_apply(frame.payload, data_dir) {
          Ok(summary) => reply(@client.CMD_OK, summary)
          Err((code, message)) => err_reply(code, message)
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
      cmd if is_function_set_command(cmd) =>
        match dispatch_function_set(frame, file_metadata_store(data_dir)) {
          Ok(payload) => (@client.CMD_OK, payload)
          Err((code, message)) => (code, @client.encode_error(code, message))
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
/// A partitioned produce: the same append, at an explicit partition.
/// The reply shape is identical to the unpartitioned one (base + count).
fn dispatch_produce_partition(
  payload : Bytes,
  data_dir : String,
) -> (Int, Bytes) {
  let (topic, partition, frame) = match
    @client.decode_partitioned_produce(payload) {
    Ok(parsed) => parsed
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let records = match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad batch: \{e}")
  }
  let log = match open_partition_log(data_dir, topic, partition) {
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
/// A partitioned fetch: the same window, at an explicit partition.
fn dispatch_fetch_partition(
  payload : Bytes,
  data_dir : String,
  rules : RuleState,
) -> (Int, Bytes) {
  let (topic, partition, from, max) = match
    @client.decode_partitioned_fetch(payload) {
    Ok(parsed) => parsed
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let log = match open_partition_log(data_dir, topic, partition) {
    Ok(log) => log
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  let entries = match log.read(from, max) {
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
  // the reply carries the partition's own watermarks: a partition is an
  // independent log, so its end is its own, not the topic's aggregate
  let out = Buffer::Buffer()
  out.write_uint_be(1U)
  out.write_uint_be(frame.length().reinterpret_as_uint())
  out.write_bytes(frame[0:frame.length()])
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
/// Deploys a pipeline document: parse, validate, compile (the same
/// publish-time static check `pipeline apply` performs, so a bad rule
/// never reaches the log path), then persist. The running server picks
/// it up on its next request through the hot-reload path it already
/// has — the editor gets a live pipeline without a restart.
fn dispatch_apply(
  payload : Bytes,
  data_dir : String,
) -> Result[Bytes, (Int, String)] {
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err((@client.ERR_BAD_PAYLOAD, "spec is not valid JSON: \{e}"))
  }
  let spec = match @spec.parse_spec(text) {
    Ok(spec) => spec
    Err(errors) => {
      let sb = StringBuilder::new()
      for i, error in errors {
        if i > 0 {
          sb.write_string("; ")
        }
        sb.write_string("\{error.path}: \{error.message}")
      }
      return Err((@client.ERR_BAD_PAYLOAD, "invalid spec: \{sb.to_string()}"))
    }
  }
  // publish-time static check: every transform must compile, with any
  // function set it references resolved from this node's store
  let store = file_metadata_store(data_dir)
  for t in spec.transforms {
    match compile_node(store, t) {
      Ok(_) => ()
      Err(e) => return Err((@client.ERR_TRANSFORM, e))
    }
  }
  let function_sets = match resolved_function_sets(spec, store) {
    Ok(sets) => sets
    Err(e) => return Err((@client.ERR_TRANSFORM, e))
  }
  let topology = @pipeline.compile(spec)
  match
    persist_applied(data_dir, topology.pipeline, json, function_sets, None) {
    Ok(_) => ()
    Err(e) => return Err((@client.ERR_STORAGE, e))
  }
  let out = @buffer.Buffer::Buffer()
  let name = @utf8.encode(topology.pipeline[0:topology.pipeline.length()])
  out.write_leb128(name.length())
  out.write_bytes(name[0:name.length()])
  out.write_leb128(topology.processes.length())
  Ok(out.to_bytes())
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
