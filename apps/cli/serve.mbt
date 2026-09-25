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
  // consumer groups (P22): a standalone broker coordinates its own —
  // the same registry the control plane runs, pointed at the same data
  // dir that holds this broker's declarations and logs. Membership is
  // in memory, committed offsets persist in groups.json, and the
  // liveness clock is the node clock (a "silent member" and a "silent
  // node" mean the same amount of time everywhere)
  let groups = GroupRegistry::new(data_dir, NODE_TIMEOUT_MS.to_int64())
  // the address advertised as the leader of every partition: the one
  // this broker bound (the same one its startup line prints)
  let self_addr = "\{host}:\{actual}"
  let handler = HubHandler::{
    on_frame: fn(frame, identity) {
      dispatch_session_frame(
        frame, data_dir, rules, ws, groups, self_addr, identity,
      )
    },
    auth: AuthGate::{ config: auth_config, data_dir },
    on_ready: fn() {
      // hot-reload checkpoint: a freshly applied spec is picked up here,
      // exactly as it was on the single-connection path
      rules.sync(data_dir)
    },
  }
  note("serving connections concurrently (one thread, poll-driven)")
  // storage housekeeping (P8): a standalone broker owns its partitions
  // alone, so its committed prefix is its own log end — the floor for
  // retention is that end, intersected with the slowest consumer's need
  // (P22: the group registry lives next door), and the policy is off
  // unless an operator asked for it (README 决策 31)
  let mut last_housekeeping : Int64 = -1L
  while true {
    let live = hub.poll_once(handler, fn(kind) {
      if kind == "websocket" {
        note("browser connected over websocket")
      }
    })
    let _ = live
    let now = @env.now().reinterpret_as_int64()
    // consumer-group members go silent on the node clock, the same
    // sweep the control plane runs: a departure moves the generation,
    // and the survivors learn it in their heartbeat reply
    for pair in groups.sweep(now) {
      let (group, member) = pair
      note(
        "group \{group}: \{member} went silent; generation moved, its partitions will be reassigned",
      )
    }
    if last_housekeeping < 0L || now - last_housekeeping >= HOUSEKEEPING_MS {
      last_housekeeping = now
      // every partition the broker hosts: the serve-side equivalent of
      // the cluster node's "retain each hosted partition" (P9) — which
      // for a standalone broker is whatever lives under topics/. The
      // policy is off unless an operator asked for it (README 决策 31),
      // and each floor is the log end lowered to the slowest consumer
      serve_retain_all(data_dir, groups, now)
    }
  }
}

///|
/// Runs the (default-off) retention policy across every partition on
/// disk. The enumeration is the same one the group coordinator uses
/// for shares — declared ∪ disk, per partition — so retention and
/// assignment can never disagree about what this broker hosts.
fn serve_retain_all(
  data_dir : String,
  groups : GroupRegistry,
  now : Int64,
) -> Unit {
  let topic_names = match @fs.list_dir("\{data_dir}/topics") {
    Ok(names) => names
    Err(_) => return // nothing hosted (yet): not an error
  }
  for name in topic_names {
    if !valid_topic(name) {
      continue
    }
    let end = disk_partition_end(data_dir, name)
    for p = 0; p < end; p = p + 1 {
      let hw = match open_partition_log(data_dir, name, p) {
        Ok(log) => log.high_watermark()
        Err(_) => continue // a directory that opens as no log: skip it
      }
      let floor = serve_partition_floor(groups, name, p, hw)
      match retain_partition(data_dir, name, p, floor, now) {
        Ok(_) => ()
        Err(e) => note("warning: \{e}")
      }
    }
  }
}

///|
/// The floor a standalone broker may delete below: its own log end,
/// lowered to the slowest group's committed offset when one exists
/// (P9's rule, served from the local registry). Only groups that
/// actually committed participate — a group that joined but never
/// committed has not started, and holding the whole log for it would
/// mean never deleting anything.
fn serve_partition_floor(
  groups : GroupRegistry,
  topic : String,
  partition : Int,
  committed : Int64,
) -> Int64 {
  let floors = groups.floors([@cluster.PartitionId::{ topic, index: partition }])
  for floor in floors {
    if floor.topic == topic && floor.partition == partition {
      if floor.floor < committed {
        return floor.floor
      }
      return committed
    }
  }
  committed
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
  groups : GroupRegistry,
  self_addr : String,
  identity : @auth.Identity?,
) -> @client.Frame {
  let _ = ws_enabled
  // the permission check is the *dispatcher's*, not each handler's
  // (P12): one place, so a new command cannot slip past it
  match identity {
    Some(identity) =>
      if !@auth.permit(identity.role, frame.cmd) {
        audit_deny(
          data_dir,
          identity.name,
          @auth.role_name(identity.role),
          frame.cmd,
          None,
          "role table",
        )
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
      let (code, payload) = dispatch_produce(frame.payload, data_dir, identity)
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_FETCH => {
      rules.sync(data_dir)
      let (code, payload) = dispatch_fetch(
        frame.payload,
        data_dir,
        rules,
        identity,
      )
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_PRODUCE_PARTITION => {
      let (code, payload) = dispatch_produce_partition(
        frame.payload,
        data_dir,
        identity,
      )
      reply_frame(frame.rid, code, payload)
    }
    @client.CMD_FETCH_PARTITION => {
      rules.sync(data_dir)
      let (code, payload) = dispatch_fetch_partition(
        frame.payload,
        data_dir,
        rules,
        identity,
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
            identity,
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
      match
        authorize_data_command(
          identity,
          data_dir,
          ref.topic,
          false,
          @client.CMD_SEGMENTS,
        ) {
        Ok(_) => ()
        Err((code, message)) => return err_frame(frame.rid, code, message)
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
      match
        authorize_data_command(
          identity,
          data_dir,
          ref.topic,
          true,
          @client.CMD_COMPACT,
        ) {
        Ok(_) => ()
        Err((code, message)) => return err_frame(frame.rid, code, message)
      }
      // the floor is the committed prefix intersected with the slowest
      // consumer's need (P9): on a standalone broker the committed
      // prefix is the log's own end, and the registry next door knows
      // what every group still needs — deleting below a group that has
      // committed there is the one storage mistake that cannot be undone
      let hw = match open_partition_log(data_dir, ref.topic, ref.partition) {
        Ok(log) => log.high_watermark()
        Err(e) => return err_frame(frame.rid, @client.ERR_STORAGE, e)
      }
      let floor = serve_partition_floor(groups, ref.topic, ref.partition, hw)
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
    // the topic family (P18/T77): a standalone broker owns its own
    // declarations, in the same store its function sets use
    @client.CMD_TOPIC_CREATE
    | @client.CMD_TOPIC_LIST
    | @client.CMD_TOPIC_DELETE =>
      match
        dispatch_topic_command(frame.cmd, frame.payload, data_dir, identity) {
        Ok(payload) => reply_frame(frame.rid, @client.CMD_OK, payload)
        Err((code, message)) => err_frame(frame.rid, code, message)
      }
    // consumer groups (P22): the standalone broker is its own
    // coordinator — same registry, same commands, same fencing as the
    // control plane's, so a member cannot tell which host it is
    // talking to and neither can the gate
    @client.CMD_GROUP_JOIN =>
      match @client.decode_group_join(frame.payload) {
        Ok(join) =>
          match groups.join(join, file_metadata_store(data_dir), now_ms()) {
            Ok(view) =>
              reply_frame(
                frame.rid,
                @client.CMD_OK,
                @client.encode_group_view(view),
              )
            Err(e) => err_frame(frame.rid, @client.ERR_GROUP, e)
          }
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
    @client.CMD_GROUP_HEARTBEAT =>
      match @client.decode_group_heartbeat(frame.payload) {
        Ok(beat) =>
          match
            groups.heartbeat(beat, file_metadata_store(data_dir), now_ms()) {
            Ok(view) =>
              reply_frame(
                frame.rid,
                @client.CMD_OK,
                @client.encode_group_view(view),
              )
            Err(e) => err_frame(frame.rid, @client.ERR_GROUP, e)
          }
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
    // leaving is a heartbeat that says goodbye: same fields, one
    // different consequence
    @client.CMD_GROUP_LEAVE =>
      match @client.decode_group_heartbeat(frame.payload) {
        Ok(beat) =>
          match groups.leave(beat.group, beat.member.id) {
            Ok(_) => reply_frame(frame.rid, @client.CMD_OK, b"")
            Err(e) => err_frame(frame.rid, @client.ERR_GROUP, e)
          }
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
    @client.CMD_GROUP_COMMIT =>
      match @client.decode_group_commit(frame.payload) {
        Ok(commit) =>
          match groups.commit(commit, file_metadata_store(data_dir)) {
            Ok(_) => reply_frame(frame.rid, @client.CMD_OK, b"")
            Err(e) => err_frame(frame.rid, @client.ERR_GROUP, e)
          }
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
      }
    @client.CMD_GROUP_DESCRIBE => {
      let group = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
      if group.length() == 0 {
        // an empty name lists the groups; the reply is JSON so the
        // CLI can print a table without a second codec
        let all : Array[Json] = []
        for entry in groups.list() {
          let (name, epoch, members, commits) = entry
          let doc : Map[String, Json] = {}
          doc["name"] = Json::string(name)
          doc["epoch"] = Json::number(epoch.to_double())
          doc["members"] = Json::number(members.to_double())
          doc["commits"] = Json::number(commits.to_double())
          all.push(Json::object(doc))
        }
        let text = Json::array(all).stringify()
        reply_frame(
          frame.rid,
          @client.CMD_OK,
          @utf8.encode(text[0:text.length()]),
        )
      } else {
        match groups.describe(group) {
          Ok(desc) =>
            reply_frame(
              frame.rid,
              @client.CMD_OK,
              @client.encode_group_description(desc),
            )
          Err(e) => err_frame(frame.rid, @client.ERR_GROUP, e)
        }
      }
    }
    // who leads a partition (P22): on a standalone broker the answer
    // is always "this one" — it hosts everything it has, and a group
    // member (or any consumer) asking where to read needs this to
    // resolve its fetches, the same question the control plane answers
    // for a cluster
    @client.CMD_LEADER =>
      match @client.decode_partition_ref(frame.payload) {
        Ok(_) =>
          reply_frame(
            frame.rid,
            @client.CMD_OK,
            @client.encode_partition_view(@client.PartitionView::{
              leader: self_addr,
              replicas: [self_addr],
              nominated: "",
            }),
          )
        Err(e) => err_frame(frame.rid, @client.ERR_BAD_PAYLOAD, e)
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
fn reply(cmd : Int, payload : Bytes) -> (Int, Bytes) {
  (cmd, payload)
}

///|
/// Structured error reply with a stable code (client-visible).
fn err_reply(code : Int, msg : String) -> (Int, Bytes) {
  reply(@client.CMD_ERR, @client.encode_error(code, msg))
}

///|
fn dispatch_produce(
  payload : Bytes,
  data_dir : String,
  identity : @auth.Identity?,
) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  match
    authorize_data_command(identity, data_dir, topic, true, @client.CMD_PRODUCE) {
    Ok(_) => ()
    Err((code, message)) => return err_reply(code, message)
  }
  let rest = reader.remaining()
  let frame = match reader.read_bytes(rest) {
    Ok(frame) => frame
    Err(_) => return err_reply(@client.ERR_BAD_PAYLOAD, "bad produce payload")
  }
  let records = match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, batch_refusal(e))
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
/// Why a produce batch was refused, in the terms the sender needs.
///
/// `ValueTooLarge` is the one failure a producer can actually fix, and
/// "bad batch: ValueTooLarge" leaves it guessing which limit it hit and
/// by how much (P15). Everything else is malformed input and keeps the
/// decoder's own words.
fn batch_refusal(error : @protocol.ProtocolError) -> String {
  match error {
    ValueTooLarge =>
      "batch exceeds the \{@protocol.MAX_BATCH_BYTES}-byte batch budget (or carries a key/value over the \{@protocol.MAX_RECORD_BYTES}-byte per-field limit); split it into smaller batches"
    other => "bad batch: \{other}"
  }
}

///|
/// A partitioned produce: the same append, at an explicit partition.
/// The reply shape is identical to the unpartitioned one (base + count).
fn dispatch_produce_partition(
  payload : Bytes,
  data_dir : String,
  identity : @auth.Identity?,
) -> (Int, Bytes) {
  let (topic, partition, frame) = match
    @client.decode_partitioned_produce(payload) {
    Ok(parsed) => parsed
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  match
    authorize_data_command(
      identity,
      data_dir,
      topic,
      true,
      @client.CMD_PRODUCE_PARTITION,
    ) {
    Ok(_) => ()
    Err((code, message)) => return err_reply(code, message)
  }
  let records = match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, batch_refusal(e))
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
  identity : @auth.Identity?,
) -> (Int, Bytes) {
  let (topic, partition, from, max) = match
    @client.decode_partitioned_fetch(payload) {
    Ok(parsed) => parsed
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  match
    authorize_data_command(
      identity,
      data_dir,
      topic,
      false,
      @client.CMD_FETCH_PARTITION,
    ) {
    Ok(_) => ()
    Err((code, message)) => return err_reply(code, message)
  }
  let log = match open_partition_log(data_dir, topic, partition) {
    Ok(log) => log
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  // the read is bounded by the reply's byte budget, not just the
  // client's record count: a window is materialised and then encoded
  // into one frame, so an unbounded window is an unmovable frame (P15)
  let entries = match log.read_bounded(from, max, @client.FETCH_WINDOW_BYTES) {
    Ok(entries) => entries
    Err(e) => return err_reply(@client.ERR_STORAGE, "read: \{e}")
  }
  let framed = match frame_window(entries, rules, from) {
    Ok(framed) => framed
    Err((code, message)) => return err_reply(code, message)
  }
  reply(
    @client.CMD_OK,
    @client.encode_fetch_reply(framed.frames, framed.scan_end),
  )
}

///|
/// Packs rule outputs into reply frames: **one frame per contiguous
/// run of origin offsets**. A record extends the current run only when
/// it names the next offset — a hole (a rule dropped the records in
/// between, or compaction removed them before the fetch ever ran) or a
/// fan-out duplicate starts a new frame, and the client's base+index
/// derivation then names each record's true offset. An unfiltered,
/// uncompacted window still packs into a single frame, byte-identical
/// to the one-frame reply this replaced.
priv struct ReplyPacker {
  frames : Array[Bytes]
  mut run : Array[@protocol.Record]
  mut run_base : Int64
  mut run_next : Int64
  /// the first contributing offset (`from` when nothing did)
  mut first : Int64
}

///|
fn ReplyPacker::new(from : Int64) -> ReplyPacker {
  ReplyPacker::{
    frames: [],
    run: [],
    run_base: from,
    run_next: from,
    first: from,
  }
}

///|
/// Adds one output record that originated at `offset`.
fn ReplyPacker::add(
  self : ReplyPacker,
  offset : Int64,
  record : @protocol.Record,
) -> Unit {
  if self.run.length() > 0 && offset != self.run_next {
    self.frames.push(@protocol.encode_frame(self.run_base, self.run))
    self.run = []
  }
  if self.run.length() == 0 {
    self.run_base = offset
  }
  if self.frames.length() == 0 && self.run.length() == 0 {
    self.first = offset
  }
  self.run.push(record)
  self.run_next = offset + 1L
}

///|
/// Flushes the open run and hands back the window's frames.
fn ReplyPacker::finish(self : ReplyPacker) -> Array[Bytes] {
  if self.run.length() > 0 {
    self.frames.push(@protocol.encode_frame(self.run_base, self.run))
    self.run = []
  }
  self.frames
}

///|
/// One windowed fetch answer, framed for truthful offsets.
priv struct FramedWindow {
  frames : Array[Bytes]
  /// where the caller should resume — it advances past filtered-away
  /// entries too, because only the server knows the scan reached them
  scan_end : Int64
  /// the first contributing offset (`from` when nothing did)
  base : Int64
  /// output records across the frames
  records : Int
}

///|
/// Turns one window of log entries into the batch frames a fetch
/// answer carries: run the topic's rule chain, then stop before the
/// reply would leave the protocol's batch budget (P15).
///
/// The cap is applied **after** the transforms, because a rule can
/// emit more records than it was handed — a budget checked against the
/// input would be a budget the output never saw. At least one entry is
/// always taken: a window that cannot carry its own first record would
/// leave a consumer unable to make progress, and refusing an oversize
/// *record* is the decoder's job.
///
/// The frames are packed by `ReplyPacker` (one per contiguous run of
/// origin offsets), so per-record offsets survive holes and fan-out:
/// the client derives each frame's records as that frame's base +
/// index, and a window whose survivors are 0, 2, 3 used to arrive as
/// one frame based at 0 — printed back as 0, 1, 2 (P18/T76, measured
/// on a compacted topic; the same shape a filter rule produces).
/// `scan_end` still advances past entries whose records were all
/// filtered, which is what lets a windowed drain tell "this partition
/// ends here" from "ask again".
fn frame_window(
  entries : Array[@log.LogEntry],
  rules : RuleState,
  from : Int64,
) -> Result[FramedWindow, (Int, String)] {
  let packer = ReplyPacker::new(from)
  let mut bytes = @protocol.FRAME_OVERHEAD_BYTES
  let mut records = 0
  let mut scan_end = from
  for entry in entries {
    let out_one = match apply_nodes(rules.chain, [entry.record]) {
      Ok(out_one) => out_one
      Err(e) => return Err((@client.ERR_TRANSFORM, "transform: \{e}"))
    }
    let mut added = 0
    for record in out_one {
      added += @protocol.record_wire_size(record)
    }
    if records > 0 && bytes + added > @client.FETCH_WINDOW_BYTES {
      break
    }
    for record in out_one {
      packer.add(entry.offset, record)
    }
    bytes += added
    records += out_one.length()
    scan_end = entry.offset + 1L
  }
  Ok(FramedWindow::{
    frames: packer.finish(),
    scan_end,
    base: packer.first,
    records,
  })
}

///|
fn dispatch_fetch(
  payload : Bytes,
  data_dir : String,
  rules : RuleState,
  identity : @auth.Identity?,
) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  match
    authorize_data_command(identity, data_dir, topic, false, @client.CMD_FETCH) {
    Ok(_) => ()
    Err((code, message)) => return err_reply(code, message)
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
  let entries = match log.read_bounded(from, max, @client.FETCH_WINDOW_BYTES) {
    Ok(entries) => entries
    Err(e) => return err_reply(@client.ERR_STORAGE, "read: \{e}")
  }
  // the frames carry the window (one per contiguous run of offsets);
  // the client derives per-record offsets from each frame's own base.
  // The dynamic rule chain (mbel transforms) runs here, on the
  // consumption path.
  let framed = match frame_window(entries, rules, from) {
    Ok(framed) => framed
    Err((code, message)) => return err_reply(code, message)
  }
  reply(
    @client.CMD_OK,
    @client.encode_fetch_reply(framed.frames, framed.scan_end),
  )
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
  identity : @auth.Identity?,
) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return err_reply(@client.ERR_BAD_PAYLOAD, e)
  }
  match
    authorize_data_command(
      identity,
      data_dir,
      topic,
      false,
      @client.CMD_FETCH_COMMITTED,
    ) {
    Ok(_) => ()
    Err((code, message)) => return err_reply(code, message)
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
  // same byte budget as the uncommitted path: the reply is one frame,
  // so the window has to be one frame's worth (P15)
  let entries = match log.read_bounded(from, take, @client.FETCH_WINDOW_BYTES) {
    Ok(entries) => entries
    Err(e) => return err_reply(@client.ERR_STORAGE, "read: \{e}")
  }
  let framed = match frame_window(entries, rules, from) {
    Ok(framed) => framed
    Err((code, message)) => return err_reply(code, message)
  }
  // the committed reply carries the frames verbatim (the client decodes
  // each with its own base, so holes survive this path too)
  let frames = Buffer::Buffer()
  for frame in framed.frames {
    frames.write_bytes(frame)
  }
  let response = @client.SyncResponse::{
    base_offset: framed.base,
    record_count: framed.records,
    high_watermark,
    log_end_offset,
    frames: frames.to_bytes(),
  }
  reply(@client.CMD_OK, @client.encode_sync_response(response))
}

///|
/// The topic family on a standalone broker (P18/T77). Declarations
/// live in the broker's own metadata store — the same one its function
/// sets use, with the same versioning — because a standalone broker
/// compiles its own applies and owns its own names. The listing is the
/// **union** of what is declared and what exists on disk (produce
/// auto-creates topics, and a listing that omits those lies by
/// omission). Delete is the first *second write path* P16 anticipated:
/// the log cache lets go of the topic's handles **before** the files
/// go, so no cached entry can outlive the data it describes.
fn dispatch_topic_command(
  cmd : Int,
  payload : Bytes,
  data_dir : String,
  identity : @auth.Identity?,
) -> Result[Bytes, (Int, String)] {
  let store = file_metadata_store(data_dir)
  let user = match identity {
    Some(identity) => identity.name
    None => ""
  }
  if cmd == @client.CMD_TOPIC_LIST {
    let wire : Array[@client.WireTopic] = []
    let declared : Map[String, Bool] = {}
    match list_topics(store) {
      Ok(topics) =>
        for topic in topics {
          declared[topic.name] = true
          wire.push(@client.WireTopic::{
            name: topic.name,
            partitions: topic.partitions,
            replication_factor: topic.replication_factor,
          })
        }
      Err(e) => return Err((@client.ERR_STORAGE, "\{e}"))
    }
    match @fs.list_dir("\{data_dir}/topics") {
      Ok(names) =>
        for name in names {
          if !valid_topic(name) || declared.get(name) is Some(_) {
            continue
          }
          // an auto-created topic: its partitions are whatever is on
          // disk, and it has never had a replica
          let mut partitions = 0
          match @fs.list_dir("\{data_dir}/topics/\{name}") {
            Ok(entries) =>
              for entry in entries {
                if entry.has_prefix("partition-") {
                  partitions += 1
                }
              }
            Err(_) => ()
          }
          if partitions > 0 {
            wire.push(@client.WireTopic::{
              name,
              partitions,
              replication_factor: 1,
            })
          }
        }
      Err(_) => () // no topics directory yet: the declared list is the answer
    }
    return Ok(@client.encode_wire_topics(wire))
  }
  let wire = match @client.decode_wire_topic(payload) {
    Ok(wire) => wire
    Err(e) => return Err((@client.ERR_BAD_PAYLOAD, e))
  }
  if cmd == @client.CMD_TOPIC_CREATE {
    if wire.replication_factor > 1 {
      return Err(
        (
          @client.ERR_BAD_PAYLOAD,
          "a standalone serve is one node: replication needs a cluster (sc + spu); declare it with --replication-factor 1",
        ),
      )
    }
    match
      create_topic(store, ClusterMetadataTopic::{
        name: wire.name,
        partitions: wire.partitions,
        replication_factor: wire.replication_factor,
      }) {
      Ok(_) => {
        note(
          "topic \{wire.name} declared (\{wire.partitions} partition(s)) on this broker",
        )
        audit_topic(data_dir, Some(user), wire.name, "declare")
        Ok(@client.encode_wire_topic(wire))
      }
      Err(e) => Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
    }
  } else {
    // delete: an absent declaration is fine — produce auto-creates
    // topics that were never declared, and the operator's intent is
    // that the data goes
    if !valid_topic(wire.name) {
      return Err((@client.ERR_BAD_PAYLOAD, "invalid topic name"))
    }
    match delete_topic(store, wire.name) {
      Ok(_) => ()
      Err(Rejected(_)) => ()
      Err(e) => return Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
    }
    let evicted = log_cache_evict_topic(data_dir, wire.name)
    match @fs.remove_dir_all("\{data_dir}/topics/\{wire.name}") {
      Ok(_) => {
        note(
          "topic \{wire.name} deleted: undeclared, \{evicted} cached log handle(s) evicted, data removed",
        )
        audit_topic(data_dir, Some(user), wire.name, "delete")
        Ok(b"")
      }
      Err(e) => Err((@client.ERR_STORAGE, "remove: \{e}"))
    }
  }
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
