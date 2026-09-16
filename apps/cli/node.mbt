// SPDX-License-Identifier: Apache-2.0
// Node roles (P3): the single binary grows the cluster shape the
// architecture calls for — one program, several subcommands
// (AGENTS §1.2). `serve` stays what it always was: a single process
// that owns its data dir and speaks the data protocol. `spu` is that
// same data node plus a control-plane relationship; `sc` is the
// control plane itself.
//
// Both loops are single-threaded on purpose. A node alternates
// between "serve whatever arrives" and "do housekeeping" using a
// listener timeout (`net-native`'s SO_RCVTIMEO), which keeps the
// process model honest: no background threads means no hidden
// concurrency in the parts the fault-injection gate will kill.

///|
/// A node's persistent identity: `<data-dir>/node.json`. Written once
/// and reused, so a restart is the *same* node returning rather than a
/// new one — which is exactly what the rejoin path is about.
struct NodeIdentity {
  id : String
  role : @client.NodeRole
  address : String
}

///|
fn node_identity_path(data_dir : String) -> String {
  "\{data_dir}/node.json"
}

///|
/// Reads the identity, or creates it from the given defaults. A node
/// that already has one keeps its id even if the command line now
/// says otherwise: identity is not a flag.
fn load_or_create_identity(
  data_dir : String,
  default_id : String,
  role : @client.NodeRole,
  address : String,
) -> Result[NodeIdentity, String] {
  let path = node_identity_path(data_dir)
  match @fs.read_file(path) {
    Ok(bytes) => {
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      let json = @json.parse(text[0:text.length()]) catch {
        e => return Err("node.json is not valid JSON: \{e}")
      }
      let obj = match json {
        Object(obj) => obj
        _ => return Err("node.json must be an object")
      }
      let id = match obj.get("id") {
        Some(String(id)) => id
        _ => default_id
      }
      let stored_role = match obj.get("role") {
        Some(String(name)) =>
          match @client.parse_node_role(name) {
            Ok(r) => r
            Err(e) => return Err("node.json: \{e}")
          }
        _ => role
      }
      let stored_address = match obj.get("address") {
        Some(String(a)) => a
        _ => address
      }
      Ok(NodeIdentity::{ id, role: stored_role, address: stored_address })
    }
    Err(_) => {
      match @fs.mkdirs(data_dir) {
        Ok(_) => ()
        Err(e) => return Err("mkdir \{data_dir}: \{e}")
      }
      let identity = NodeIdentity::{ id: default_id, role, address }
      let doc_map : Map[String, Json] = {}
      doc_map["id"] = Json::string(identity.id)
      doc_map["role"] = Json::string(@client.role_name(identity.role))
      doc_map["address"] = Json::string(identity.address)
      let doc = Json::object(doc_map)
      let text = doc.stringify(indent=2)
      match @fs.write_file(path, @utf8.encode(text[0:text.length()])) {
        Ok(_) => ()
        Err(e) => return Err("write \{path}: \{e}")
      }
      Ok(identity)
    }
  }
}

///|
/// The control-plane client used by an spu: one short-lived
/// connection per call (register / heartbeat), handshake included.
/// Short-lived on purpose — a persistent control channel is a
/// reconnect state machine, and this milestone's job is the cluster
/// semantics, not a connection cache.
fn control_call(
  sc_addr : String,
  cmd : Int,
  payload : Bytes,
) -> Result[Bytes, String] {
  let (host, port) = parse_listen_addr(sc_addr)
  let conn = match @client.Conn::tcp(host, port) {
    Ok(conn) => conn
    Err(e) => return Err("connect \{sc_addr}: \{e}")
  }
  let result = control_call_on(conn, cmd, payload)
  (conn.close)()
  result
}

///|
fn control_call_on(
  conn : @client.Conn,
  cmd : Int,
  payload : Bytes,
) -> Result[Bytes, String] {
  match
    conn.send_frame(@client.Frame::{
      cmd: @client.CMD_HELLO,
      rid: 0,
      payload: @client.encode_hello(@client.PROTOCOL_VERSION, 0),
    }) {
    Ok(_) => ()
    Err(e) => return Err("hello: \{e}")
  }
  match conn.recv_frame() {
    Ok(Some(frame)) =>
      if frame.cmd == @client.CMD_ERR {
        let (code, msg) = @client.decode_error(frame.payload)
        return Err("handshake rejected (code \{code}): \{msg}")
      }
    Ok(None) => return Err("control plane closed during handshake")
    Err(e) => return Err("handshake: \{e}")
  }
  match conn.send_frame(@client.Frame::{ cmd, rid: 1, payload }) {
    Ok(_) => ()
    Err(e) => return Err("send: \{e}")
  }
  match conn.recv_frame() {
    Ok(Some(frame)) =>
      if frame.cmd == @client.CMD_ERR {
        let (code, msg) = @client.decode_error(frame.payload)
        Err("rejected (code \{code}): \{msg}")
      } else {
        Ok(frame.payload)
      }
    Ok(None) => Err("control plane closed before replying")
    Err(e) => Err("reply: \{e}")
  }
}

///|
/// Sends the node's record to the control plane (register or
/// heartbeat — the two differ only in what the control plane does
/// with the fact that the node is *new*).
fn report_to_control(
  sc_addr : String,
  record : @client.NodeRecord,
  cmd : Int,
) -> Result[Unit, String] {
  match control_call(sc_addr, cmd, @client.encode_node(record)) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// `moonflux spu --id A --listen host:port --data-dir D [--sc host:port]`
///
/// A data node: serves the data protocol exactly as `serve` does (same
/// handler, same command codes — a `consume --remote` against an spu
/// cannot tell the difference), and reports itself to the control
/// plane on a timer. Without `--sc` it is simply a data node that
/// nobody is watching, which is a legitimate way to run one.
fn cmd_spu(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let addr = flags.require("listen")
  let id = flags.require("id")
  let sc = flags.get("sc")
  let (host, port) = parse_listen_addr(addr)
  let identity = match load_or_create_identity(data_dir, id, Spu, addr) {
    Ok(identity) => identity
    Err(e) => fail("node identity: \{e}")
  }
  let listener = match @net.TcpListener::bind_listen(host, port) {
    Ok(l) => l
    Err(e) => fail("bind \{host}:\{port}: \{e}")
  }
  let actual = match listener.local_port() {
    Ok(port) => port
    Err(_) => port
  }
  match listener.set_accept_timeout_ms(HOUSEKEEPING_INTERVAL_MS) {
    Ok(_) => ()
    Err(e) => fail("accept timeout: \{e}")
  }
  note(
    "moonflux spu '\{identity.id}' listening on \{host}:\{actual} (data dir \{data_dir})",
  )
  match sc {
    Some(sc_addr) =>
      note(
        "  reporting to control plane \{sc_addr} every \{HOUSEKEEPING_INTERVAL_MS}ms",
      )
    None => note("  no control plane configured (standalone data node)")
  }
  let rules = RuleState::new()
  let mut last_report : Int64 = -1L
  let mut registered = false
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_connection(stream, data_dir, rules)
        let _ = stream.close()
      }
      Err(TimedOut) => () // housekeeping tick
      Err(e) => fail("accept: \{e}")
    }
    match sc {
      None => ()
      Some(sc_addr) => {
        let now = now_ms()
        if last_report < 0L ||
          now - last_report >= HOUSEKEEPING_INTERVAL_MS.to_int64() {
          last_report = now
          let leo = local_leo(data_dir)
          let record = @client.NodeRecord::{
            id: identity.id,
            role: Spu,
            address: "\{host}:\{actual}",
            leo,
          }
          let cmd = if registered {
            @client.CMD_HEARTBEAT
          } else {
            @client.CMD_REGISTER
          }
          match report_to_control(sc_addr, record, cmd) {
            Ok(_) =>
              if not(registered) {
                registered = true
                note(
                  "registered with control plane \{sc_addr} as \{identity.id}",
                )
              }
            Err(e) => {
              // a control plane that is down must not take the data
              // node down: it keeps serving, and re-registers later
              if registered {
                registered = false
              }
              note("warning: control plane \{sc_addr} unreachable: \{e}")
            }
          }
        }
      }
    }
  }
}

///|
/// `moonflux sc --listen host:port --data-dir D`
///
/// The control plane: accepts node reports, keeps the table, and
/// sweeps for silence. It does not touch topic logs — that is the
/// data plane's job, and keeping the two apart is what lets a data
/// node run without it.
fn cmd_sc(argv : Array[String]) -> Unit {
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
  match listener.set_accept_timeout_ms(HOUSEKEEPING_INTERVAL_MS) {
    Ok(_) => ()
    Err(e) => fail("accept timeout: \{e}")
  }
  note(
    "moonflux sc listening on \{host}:\{actual} (data dir \{data_dir}, liveness timeout \{NODE_TIMEOUT_MS}ms)",
  )
  let table = NodeTable::new(NODE_TIMEOUT_MS)
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_control_connection(stream, table)
        let _ = stream.close()
      }
      Err(TimedOut) => ()
      Err(e) => fail("accept: \{e}")
    }
    let swept = table.sweep(now_ms())
    for node in swept {
      note("node \{node} is offline (no heartbeat within \{NODE_TIMEOUT_MS}ms)")
    }
  }
}

///|
/// How often a node does housekeeping (its accept timeout, and the
/// heartbeat cadence). Deliberately faster than the liveness timeout
/// so that a healthy node is never late by accident.
const HOUSEKEEPING_INTERVAL_MS : Int = 500

///|
/// How long the control plane waits before calling a node offline.
/// Must be a comfortable multiple of the heartbeat interval: three
/// missed beats is a failure, one is a hiccup.
const NODE_TIMEOUT_MS : Int = 3000

///|
/// The host clock in milliseconds. Nodes read it here rather than in
/// the kernel (AGENTS §5); every call site is a deliberate one.
/// `@env.now()` is already milliseconds since the epoch — scaling it
/// again silently turns a 3-second liveness timeout into a
/// 3-kilosecond one, which is exactly how a "node never goes offline"
/// bug looks from the outside.
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// The node's own log end for its single partition, or 0 when it holds
/// no data yet. Reported to the control plane so that election can
/// prefer the replica that is furthest along (core/replica decides).
/// Read-only by intent: a heartbeat must not create a log for a topic
/// this node has never been given, so the segment is only opened when
/// it already exists.
fn local_leo(data_dir : String) -> Int64 {
  let applied = match load_applied(data_dir) {
    Some(applied) => applied
    None => return 0L
  }
  let partition = applied.spec.topic.name
  match @fs.exists(topic_log_path(data_dir, partition)) {
    Ok(true) => ()
    _ => return 0L
  }
  let handle = match
    @fs.open_segment_file(topic_log_path(data_dir, partition)) {
    Ok(handle) => handle
    Err(_) => return 0L
  }
  match @log.SegmentedLog::open(handle) {
    Ok(log) => log.high_watermark()
    Err(_) => 0L
  }
}

///|
/// One node as the control plane sees it.
struct NodeEntry {
  record : @client.NodeRecord
  last_seen_ms : Int64
  online : Bool
}

///|
/// The control plane's node table. Liveness is derived, never
/// declared: a node is online because it spoke recently enough, and
/// the transition to offline is computed from the clock rather than
/// triggered by an event — the same level-triggered stance as
/// core/cluster's reconcile.
struct NodeTable {
  entries : Array[NodeEntry]
  timeout_ms : Int
}

///|
fn NodeTable::new(timeout_ms : Int) -> NodeTable {
  NodeTable::{ entries: [], timeout_ms }
}

///|
fn NodeTable::find(self : NodeTable, id : String) -> NodeEntry? {
  for entry in self.entries {
    if entry.record.id == id {
      return Some(entry)
    }
  }
  None
}

///|
/// Records a report. First contact is a registration; later contact
/// is a heartbeat (and keeps the newest LEO — a node that restarted
/// must not look like it lost its data).
fn NodeTable::observe(
  self : NodeTable,
  record : @client.NodeRecord,
  now : Int64,
) -> Bool {
  for i in 0..<self.entries.length() {
    if self.entries[i].record.id == record.id {
      let was_online = self.entries[i].online
      self.entries[i] = NodeEntry::{ record, last_seen_ms: now, online: true }
      return was_online
    }
  }
  self.entries.push(NodeEntry::{ record, last_seen_ms: now, online: true })
  true
}

///|
/// Marks nodes offline whose last report is older than the timeout;
/// returns the ones that just went offline (so the caller can say so
/// once rather than every tick).
fn NodeTable::sweep(self : NodeTable, now : Int64) -> Array[String] {
  let went_offline : Array[String] = []
  for i in 0..<self.entries.length() {
    if self.entries[i].online {
      let silence = now - self.entries[i].last_seen_ms
      if silence > self.timeout_ms.to_int64() {
        self.entries[i] = NodeEntry::{
          record: self.entries[i].record,
          last_seen_ms: self.entries[i].last_seen_ms,
          online: false,
        }
        went_offline.push(self.entries[i].record.id)
      }
    }
  }
  went_offline
}

///|
/// The table as the wire sees it: only online nodes, id-sorted so two
/// reads of an unchanged cluster are byte-identical.
fn NodeTable::snapshot(self : NodeTable) -> Array[@client.NodeRecord] {
  let out : Array[@client.NodeRecord] = []
  for entry in self.entries {
    if entry.online {
      out.push(entry.record)
    }
  }
  out.sort_by(fn(a, b) { a.id.compare(b.id) })
  out
}

///|
/// Handles one control-plane connection: the v2 handshake, then
/// REGISTER / HEARTBEAT / NODES. Data commands against the control
/// port get a structured refusal — the control plane is not a broker,
/// and silently proxying would hide a misconfigured client.
fn handle_control_connection(
  stream : @net.TcpStream,
  table : NodeTable,
) -> Unit {
  let conn = @client.Conn::from_stream(stream)
  let hello = match conn.recv_first() {
    @client.Got(frame) => frame
    @client.Eof => return
    @client.Garbage(_) => return
    @client.WrongVersion(_) => {
      let _ = conn.send_frame(@client.Frame::{
        cmd: @client.CMD_ERR,
        rid: 0,
        payload: @client.encode_error(
          @client.ERR_UNSUPPORTED_VERSION,
          "control plane speaks frame version \{@client.PROTOCOL_VERSION}",
        ),
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
        "expected HELLO first",
      ),
    })
    return
  }
  let _ = conn.send_frame(@client.Frame::{
    cmd: @client.CMD_WELCOME,
    rid: hello.rid,
    payload: @client.encode_hello(@client.PROTOCOL_VERSION, 0),
  })
  while true {
    let frame = match conn.recv_frame() {
      Ok(Some(frame)) => frame
      Ok(None) => return
      Err(_) => return
    }
    let reply = match frame.cmd {
      @client.CMD_REGISTER | @client.CMD_HEARTBEAT =>
        match @client.decode_node(frame.payload) {
          Ok(record) => {
            let is_new = table.observe(record, now_ms())
            if is_new && frame.cmd == @client.CMD_REGISTER {
              note(
                "node \{record.id} (\{@client.role_name(record.role)}) registered at \{record.address}, leo \{record.leo}",
              )
            }
            Ok(b"")
          }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, "bad node record: \{e}"))
        }
      @client.CMD_NODES => Ok(@client.encode_nodes(table.snapshot()))
      @client.CMD_PRODUCE | @client.CMD_FETCH =>
        Err(
          (
            @client.ERR_WRONG_ROLE,
            "this is the control plane; produce/fetch belong to a data node",
          ),
        )
      _ => Err((@client.ERR_UNKNOWN_COMMAND, "unknown command \{frame.cmd}"))
    }
    let frame_out = match reply {
      Ok(payload) =>
        @client.Frame::{ cmd: @client.CMD_OK, rid: frame.rid, payload }
      Err((code, message)) =>
        @client.Frame::{
          cmd: @client.CMD_ERR,
          rid: frame.rid,
          payload: @client.encode_error(code, message),
        }
    }
    match conn.send_frame(frame_out) {
      Ok(_) => ()
      Err(_) => return
    }
  }
}
