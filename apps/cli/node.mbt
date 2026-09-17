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
  control_call_with_timeout(sc_addr, cmd, payload, CONTROL_CALL_TIMEOUT_MS)
}

///|
/// The peer-to-peer deadline. Shorter than the control plane's on
/// purpose (P7): a node talks to *every* partition's leader each tick,
/// and a busy peer must not hold this node's loop — the same "deadline,
/// not a wait" rule as the control path, tightened because the fan-out
/// is now per partition.
///
/// A missed call is not a failure of the protocol: replication is
/// convergent and the next tick retries, so a short deadline costs a
/// retry, never a record (failures are reported once, not per tick).
const PEER_CALL_TIMEOUT_MS : Int = 2000

///|
/// How long a peer connection may take to establish. A listening peer
/// accepts from the backlog immediately, so this is a routing check
/// (nothing there) rather than a patience setting.
const CONNECT_TIMEOUT_MS : Int = 300

///|
fn control_call_with_timeout(
  addr : String,
  cmd : Int,
  payload : Bytes,
  timeout_ms : Int,
) -> Result[Bytes, String] {
  let (host, port) = parse_listen_addr(addr)
  // a deadline, not a wait: every node is a single-threaded loop, so
  // a busy peer must fail this call rather than block this node's
  // whole tick
  let conn = match @native.tcp_with_timeout(host, port, timeout_ms) {
    Ok(conn) => conn
    Err(e) => return Err("connect \{addr}: \{e}")
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
      payload: @client.encode_hello(1, 0),
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
  reports : Array[@client.PartitionReport],
  cmd : Int,
) -> Result[Bytes, String] {
  let payload = match
    control_call(sc_addr, cmd, @client.encode_node_full(record, reports)) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  // the reply carries this node's assignments: placement is the
  // control plane's state, and the heartbeat is the channel that
  // delivers it (README 决策 20's pattern, applied to placement)
  @client.decode_assignments(payload)
  |> Result::map(fn(_assignments) { payload })
}

///|
/// The assignments in a heartbeat reply, or an empty list when the
/// reply is empty (a control plane with no placements).
fn assignments_of(
  payload : Bytes,
) -> Result[Array[@client.AssignmentView], String] {
  match @client.decode_assignments_full(payload) {
    Ok(parts) => {
      let (assignments, _floors, _revision) = parts
      Ok(assignments)
    }
    Err(e) => Err(e)
  }
}

///|
/// The same reply's floors, keyed the way the host table looks them up.
fn floors_of(payload : Bytes) -> Result[Array[@client.GroupFloor], String] {
  match @client.decode_assignments_full(payload) {
    Ok(parts) => {
      let (_assignments, floors, _revision) = parts
      Ok(floors)
    }
    Err(e) => Err(e)
  }
}

///|
/// The cluster pipeline revision the control plane reports, or None
/// when this reply predates the field (an older control plane).
fn pipeline_revision_of(payload : Bytes) -> Int64? {
  match @client.decode_assignments_full(payload) {
    Ok(parts) => {
      let (_assignments, _floors, revision) = parts
      if revision > 0L {
        Some(revision)
      } else {
        None
      }
    }
    Err(_) => None
  }
}

///|
/// The floor a host should remember for a partition: the entry the
/// coordinator sent, or None when it sent nothing (no group consumes
/// this partition).
fn floor_for(
  floors : Array[@client.GroupFloor],
  topic : String,
  partition : Int,
) -> Int64? {
  for floor in floors {
    if floor.topic == topic && floor.partition == partition {
      return Some(floor.floor)
    }
  }
  None
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
  // The accept timeout is the *loop* tick, not the heartbeat cadence:
  // a blocking accept makes every poll cost a full timeout, and the
  // pump polls several times per cycle (P7 measured 1.0-1.5s client
  // latency, all of it spent waiting for an idle accept). The heartbeat
  // keeps its 500ms rhythm through its own gate below.
  match listener.set_accept_timeout_ms(POLL_TICK_MS) {
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
  // A data node serves many peers at once (P7): every partition's
  // followers pull from its leader, so "one connection at a time" turns
  // into peers starving each other — the same problem `serve` solved in
  // P5, with the same hub. The housekeeping tick (heartbeat, placement,
  // replication) runs between polls.
  // What this node hosts is the control plane's decision, delivered in
  // the heartbeat reply; a node with no control plane falls back to the
  // degenerate single-node placement (partition 0 of its applied topic)
  // and says so, because then nobody else is holding the data.
  let hosts = HostTable::new(data_dir, identity.id, "\{host}:\{actual}")
  let sc_addr = match sc {
    Some(addr) => addr
    None => ""
  }
  hosts.applied_topic = applied_topic(data_dir)
  if sc is None {
    hosts.self_place("no control plane configured")
    if hosts.applied_topic.length() == 0 {
      note(
        "no pipeline applied yet: this node serves requests but hosts nothing",
      )
    }
  }
  // The poll timeout must stay well under the peer deadline: a busy
  // node only notices an inbound pull when it polls, and a follower
  // that waits longer than PEER_CALL_TIMEOUT_MS for its handshake
  // gives up (P7 measured exactly that: 500ms poll vs 300ms
  // deadline, every replication call timing out). The heartbeat keeps
  // its own 500ms cadence through the gate below.
  let hub = ConnectionHub::new(listener, POLL_TICK_MS)
  let handler = HubHandler::{
    on_frame: fn(frame) {
      let reply = dispatch_data_frame(frame, data_dir, rules, hosts, sc_addr)
      @client.Frame::{ cmd: reply.0, rid: frame.rid, payload: reply.1 }
    },
    on_ready: fn() { () },
  }
  // the pump: what every outbound call does first. It is the same
  // poll the main loop runs, so a peer's inbound handshake is served
  // between our calls rather than after all of them.
  let pump = fn() { let _ = hub.poll_once(handler, fn(_kind) { () }) }
  let mut last_report : Int64 = -1L
  let mut registered = false
  let mut last_assignment_count = -1
  // adoption failures are reported once per revision, not per heartbeat
  let adoption = AdoptionState::{ failed_revision: -1L, reported: false }
  while true {
    let _ = hub.poll_once(handler, fn(_kind) { () })
    match sc {
      None => ()
      Some(sc_addr) => {
        let now = now_ms()
        if last_report < 0L ||
          now - last_report >= HOUSEKEEPING_INTERVAL_MS.to_int64() {
          last_report = now
          // the node-level leo stays: it is the compat field every
          // pre-P7 reader knows, and it means partition 0 of the
          // applied topic (the real truth travels per partition below)
          let leo = local_leo(data_dir)
          let record = @client.NodeRecord::{
            id: identity.id,
            role: Spu,
            address: "\{host}:\{actual}",
            leo,
          }
          hosts.applied_topic = applied_topic(data_dir)
          let cmd = if registered {
            @client.CMD_HEARTBEAT
          } else {
            @client.CMD_REGISTER
          }
          match report_to_control(sc_addr, record, hosts.reports(), cmd) {
            Ok(payload) => {
              if not(registered) {
                registered = true
                note(
                  "registered with control plane \{sc_addr} as \{identity.id}",
                )
              }
              // placement arrives with the reply: adopt what is
              // assigned here, drop what is not, then do this node's
              // half of every partition it holds
              match assignments_of(payload) {
                Ok(assignments) => {
                  if assignments.length() != last_assignment_count {
                    last_assignment_count = assignments.length()
                    note(
                      "placement: \{assignments.length()} partition(s) assigned to this node",
                    )
                  }
                  let floors = match floors_of(payload) {
                    Ok(floors) => floors
                    Err(_) => []
                  }
                  // the cluster's pipeline (P11): the heartbeat carries
                  // its revision, and the document is pulled only when
                  // that revision is ahead of what this node runs
                  match pipeline_revision_of(payload) {
                    Some(revision) => {
                      let _ = adopt_cluster_pipeline(
                        data_dir,
                        sc_addr,
                        file_metadata_store(data_dir),
                        revision,
                        adoption,
                      )
                    }
                    None => ()
                  }
                  for assignment in assignments {
                    hosts.adopt(
                      assignment,
                      floor_for(floors, assignment.topic, assignment.partition),
                    )
                  }
                  hosts.retain(assignments)
                  // one partition at a time, serving connections in
                  // between: the fan-out must not starve the peers
                  // whose pulls this node is answering
                  for i = 0; i < hosts.host_count(); i = i + 1 {
                    hosts.tick_one(sc_addr, i, pump)
                  }
                }
                Err(e) =>
                  note("warning: cannot read this node's assignments: \{e}")
              }
            }
            Err(e) =>
              // A control plane that is down must not take the data node
              // down: it keeps serving, and re-registers later. The
              // warning is a *transition* report — one line when contact
              // is lost, then silence until it comes back (the P3 rule
              // for derived liveness, applied to this call as well: a
              // line every 500ms forever is how a log stops being read).
              if registered {
                registered = false
                note(
                  "warning: control plane \{sc_addr} unreachable: \{e} (this node keeps serving the pipeline it has)",
                )
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
  // consumer groups: the control plane coordinates them with the same
  // liveness timeout it uses for nodes, so "a member went silent" and
  // "a node went silent" mean the same amount of time (P9)
  let groups = GroupRegistry::new(data_dir, NODE_TIMEOUT_MS.to_int64())
  // the cluster's applied pipeline: the authority nodes pull from (P11)
  let asset = ClusterAsset::load(data_dir)
  let store = file_metadata_store(data_dir)
  let placement = PlacementState::new(data_dir)
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_control_connection(
          stream, table, placement, store, groups, asset,
        )
        let _ = stream.close()
      }
      Err(TimedOut) => ()
      Err(e) => fail("accept: \{e}")
    }
    // consumer-group members go silent on the same clock: the sweep
    // moves their groups' generations, which is what starts the next
    // rebalance (the survivors learn it in their heartbeat reply)
    let left = groups.sweep(now_ms())
    for pair in left {
      let (group, member) = pair
      note(
        "group \{group}: \{member} went silent; generation moved, its partitions will be reassigned",
      )
    }
    let swept = table.sweep(now_ms())
    for node in swept {
      note("node \{node} is offline (no heartbeat within \{NODE_TIMEOUT_MS}ms)")
    }
    placement.tick(table)
  }
}

///|
/// How long a node-to-node control call may take. Comfortably longer
/// than a healthy round trip (sub-millisecond on loopback) and
/// comfortably shorter than the liveness timeout, so a stuck peer
/// costs one tick instead of the whole cluster.
const CONTROL_CALL_TIMEOUT_MS : Int = 1000

///|
/// How long the node's event loop may wait for a connection before
/// looking at its housekeeping clock again. Small on purpose: it is
/// the worst-case delay before an inbound replication pull is served.
const POLL_TICK_MS : Int = 50

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
  let name = applied.spec.topic.name
  if !partition_has_bytes(data_dir, name, 0) {
    return 0L
  }
  // opening is safe here (there are bytes): it also migrates a pre-P8
  // single file into the segmented layout
  match open_partition_log(data_dir, name, 0) {
    Ok(log) => log.high_watermark()
    Err(_) => 0L
  }
}

///|
/// One node as the control plane sees it.
struct NodeEntry {
  record : @client.NodeRecord
  /// per-partition progress (P7). `record.leo` stays for readers that
  /// predate this section; elections read these.
  reports : Array[@client.PartitionReport]
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
/// Looks a node up by the address it advertises. Placement and
/// elections speak in addresses (that is what peers dial), while the
/// table is keyed by node id — this is the one translation between
/// the two, kept next to the table it reads.
fn NodeTable::find_address(self : NodeTable, address : String) -> NodeEntry? {
  for entry in self.entries {
    if entry.record.address == address {
      return Some(entry)
    }
  }
  None
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
  reports : Array[@client.PartitionReport],
  now : Int64,
) -> Bool {
  for i in 0..<self.entries.length() {
    if self.entries[i].record.id == record.id {
      let was_online = self.entries[i].online
      self.entries[i] = NodeEntry::{
        record,
        reports,
        last_seen_ms: now,
        online: true,
      }
      return was_online
    }
  }
  self.entries.push(NodeEntry::{
    record,
    reports,
    last_seen_ms: now,
    online: true,
  })
  true
}

///|
/// The last LEO this node reported for a partition, or 0 when it has
/// never mentioned it (a node that holds nothing is not a candidate,
/// and 0 says exactly that).
fn NodeTable::leo_of(
  self : NodeTable,
  address : String,
  topic : String,
  partition : Int,
) -> Int64 {
  match self.find_address(address) {
    Some(entry) => {
      for report in entry.reports {
        if report.topic == topic && report.partition == partition {
          return report.leo
        }
      }
      0L
    }
    None => 0L
  }
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
          reports: self.entries[i].reports,
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
  placement : PlacementState,
  store : MetadataStore,
  groups : GroupRegistry,
  asset : ClusterAsset,
) -> Unit {
  let conn = @native.from_stream(stream)
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
    payload: @client.encode_hello(1, 0),
  })
  while true {
    let frame = match conn.recv_frame() {
      Ok(Some(frame)) => frame
      Ok(None) => return
      Err(_) => return
    }
    let reply = match frame.cmd {
      @client.CMD_REGISTER | @client.CMD_HEARTBEAT =>
        match @client.decode_node_full(frame.payload) {
          Ok(parts) => {
            let (record, reports) = parts
            let first_contact = table.observe(record, reports, now_ms())
            if first_contact && frame.cmd == @client.CMD_REGISTER {
              note(
                "node \{record.id} (\{@client.role_name(record.role)}) registered at \{record.address}",
              )
            }
            // the reply carries this node's assignments: placement is
            // the control plane's state, and this is the channel the
            // node already polls (README 决策 29)
            let assignments = placement.assignments_for(record.address)
            // the floors: what consumers still need on the partitions
            // this node holds, so its retention can respect them
            let partitions : Array[@cluster.PartitionId] = []
            for assignment in assignments {
              partitions.push(@cluster.PartitionId::{
                topic: assignment.topic,
                index: assignment.partition,
              })
            }
            Ok(
              @client.encode_assignments_full(
                assignments,
                groups.floors(partitions),
                asset.revision,
              ),
            )
          }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, "bad node record: \{e}"))
        }
      @client.CMD_NODES => Ok(@client.encode_nodes(table.snapshot()))
      @client.CMD_TOPIC_CREATE =>
        match @client.decode_wire_topic(frame.payload) {
          Ok(wire) =>
            match
              create_topic(store, ClusterMetadataTopic::{
                name: wire.name,
                partitions: wire.partitions,
                replication_factor: wire.replication_factor,
              }) {
              Ok(_) => {
                note(
                  "topic \{wire.name} declared (\{wire.partitions} partition(s), \{wire.replication_factor} replica(s))",
                )
                // the next reconcile tick turns the declaration into
                // placement — no further instruction is needed
                Ok(@client.encode_wire_topic(wire))
              }
              Err(e) => Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      @client.CMD_TOPIC_LIST =>
        match list_topics(store) {
          Ok(topics) => {
            let wire : Array[@client.WireTopic] = []
            for topic in topics {
              wire.push(@client.WireTopic::{
                name: topic.name,
                partitions: topic.partitions,
                replication_factor: topic.replication_factor,
              })
            }
            Ok(@client.encode_wire_topics(wire))
          }
          Err(e) => Err((@client.ERR_STORAGE, "\{e}"))
        }
      @client.CMD_TOPIC_DELETE =>
        match @client.decode_wire_topic(frame.payload) {
          Ok(wire) =>
            match delete_topic(store, wire.name) {
              Ok(_) => {
                note(
                  "topic \{wire.name} undeclared; its partitions will be removed",
                )
                Ok(b"")
              }
              Err(e) => Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      // the cluster's pipeline (P11): published here, pulled by nodes
      @client.CMD_CLUSTER_PIPELINE_APPLY => {
        let text = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
        match asset.publish(text, store) {
          Ok(revision) => {
            note(
              "cluster pipeline applied (revision \{revision}, \{text.length()} bytes); data nodes will pull it on their next heartbeat",
            )
            Ok(
              @client.encode_cluster_pipeline(@client.ClusterPipeline::{
                revision,
                spec_json: "",
              }),
            )
          }
          Err(e) => Err((@client.ERR_TRANSFORM, e))
        }
      }
      @client.CMD_CLUSTER_PIPELINE_FETCH =>
        // the empty payload asks "which revision?"; anything else asks
        // for the document. The revision rides every heartbeat; the
        // document only when it changed.
        if frame.payload.length() == 0 {
          Ok(
            @client.encode_cluster_pipeline(@client.ClusterPipeline::{
              revision: asset.revision,
              spec_json: "",
            }),
          )
        } else if asset.spec_json.length() == 0 {
          Err(
            (@client.ERR_BAD_PAYLOAD, "no pipeline is applied on this cluster"),
          )
        } else {
          Ok(
            @client.encode_cluster_pipeline(@client.ClusterPipeline::{
              revision: asset.revision,
              spec_json: asset.spec_json,
            }),
          )
        }
      @client.CMD_FUNCTION_SET_FETCH => {
        // the control plane is the authoritative copy of the rule
        // assets; a node that needs one pulls it (P11/T54). The reply
        // is the stored document as-is — including its revision, which
        // is the number a node compares against its own to know
        // whether it is behind.
        let name = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
        match get_function_set(store, name) {
          Ok(set) => {
            let text = encode_function_set_doc(set).stringify()
            Ok(@utf8.encode(text[0:text.length()]))
          }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
        }
      }
      // consumer groups (P9): the control plane is the coordinator
      @client.CMD_GROUP_JOIN =>
        match @client.decode_group_join(frame.payload) {
          Ok(join) =>
            match groups.join(join, store, now_ms()) {
              Ok(view) => Ok(@client.encode_group_view(view))
              Err(e) => Err((@client.ERR_GROUP, e))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      @client.CMD_GROUP_HEARTBEAT =>
        match @client.decode_group_heartbeat(frame.payload) {
          Ok(beat) =>
            match groups.heartbeat(beat, store, now_ms()) {
              Ok(view) => Ok(@client.encode_group_view(view))
              Err(e) => Err((@client.ERR_GROUP, e))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      // leaving is a heartbeat that says goodbye: same fields, one
      // different consequence
      @client.CMD_GROUP_LEAVE =>
        match @client.decode_group_heartbeat(frame.payload) {
          Ok(beat) =>
            match groups.leave(beat.group, beat.member.id) {
              Ok(_) => Ok(b"")
              Err(e) => Err((@client.ERR_GROUP, e))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      @client.CMD_GROUP_COMMIT =>
        match @client.decode_group_commit(frame.payload) {
          Ok(commit) =>
            match groups.commit(commit, store) {
              Ok(_) => Ok(b"")
              Err(e) => Err((@client.ERR_GROUP, e))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
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
          Ok(@utf8.encode(text[0:text.length()]))
        } else {
          match groups.describe(group) {
            Ok(desc) => Ok(@client.encode_group_description(desc))
            Err(e) => Err((@client.ERR_GROUP, e))
          }
        }
      }
      cmd if is_function_set_command(cmd) =>
        match dispatch_function_set(frame, store) {
          Ok(payload) => Ok(payload)
          Err((_code, message)) => Err((@client.ERR_BAD_PAYLOAD, message))
        }
      @client.CMD_CONFIRM =>
        match @client.decode_confirmation(frame.payload) {
          Ok(confirmation) =>
            match
              placement.confirm(
                confirmation.partition.topic,
                confirmation.partition.partition,
                confirmation.candidate,
              ) {
              Ok(_) => Ok(b"")
              Err(e) => Err((@client.ERR_SEQUENCE, e))
            }
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
      @client.CMD_LEADER =>
        match @client.decode_partition_ref(frame.payload) {
          Ok(ref) =>
            Ok(
              @client.encode_partition_view(
                placement.view(ref.topic, ref.partition),
              ),
            )
          Err(e) => Err((@client.ERR_BAD_PAYLOAD, e))
        }
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

// ---------------------------------------------------------------------
// Replication (T22): the leader serves raw frames, followers pull
// them. The reference system replicates follower-pull and so does
// this — a leader that pushed would need per-follower send state and a
// backpressure story, and the milestone's gate is about watermarks,
// not about inventing a second protocol.

///|
/// What a data node knows about the partition it hosts. One instance
/// per process, mutated by the housekeeping tick and read by request
/// handlers — the same pattern as RuleState, and the only shared
/// mutable state in the process (single-threaded by design).
struct PartitionHost {
  data_dir : String
  /// which partition of the topic this host owns (P7): every call the
  /// host makes on the wire names this pair, so the `partition: 0`
  /// literal that used to live in the replication helpers is gone
  partition : Int
  /// the topic this node was given, or "" when nothing is applied;
  /// mutable because a node learns it from the applied pipeline
  topic : String
  /// the address this node advertises to peers
  address : String
  /// this node's identity
  node_id : String
  /// leader-side progress ledger; only meaningful while leading
  mut ledger : @replica.ProgressLedger?
  /// who leads the partition right now ("" = nobody yet)
  mut leader_addr : String
  /// the addresses that hold the partition (from the control plane)
  mut replicas : Array[String]
  /// set once the follower has reported its first successful pull
  mut caught_up : Bool
  /// the LEO this host last reported to its leader (-1 = never), so an
  /// idle follower does not re-ack a position the leader already knows
  mut last_acked : Int64
  /// whether the *first* replication failure has been reported. A
  /// follower that has never succeeded says why once instead of every
  /// tick — silence here cost a debugging session (P7).
  mut reported_failure : Bool
  /// the replica the control plane is currently offering this
  /// partition to ("" = no election pending); carried in the
  /// assignment so a candidate needs no extra round trip to notice
  mut nominated : String
  /// the oldest offset consumers still need (P9/T50). `None` means no
  /// group is consuming this partition — which is *not* the same as a
  /// group sitting at zero, and retention must not conflate them.
  mut group_floor : Int64?
  /// the follower's persistent link to this partition's leader (P10).
  /// Dropped on any error, redialled on the next round; `None` means
  /// "not connected", which is the normal state for a leader.
  mut link : SyncLink?
}

///|
fn PartitionHost::new(
  data_dir : String,
  node_id : String,
  address : String,
  topic : String,
  partition : Int,
) -> PartitionHost {
  PartitionHost::{
    data_dir,
    partition,
    topic,
    address,
    node_id,
    ledger: None,
    leader_addr: "",
    replicas: [],
    caught_up: false,
    last_acked: -1L,
    reported_failure: false,
    nominated: "",
    group_floor: None,
    link: None,
  }
}

///|
/// An address for a log line: "" is a state, not a typo (nobody leads
/// this partition right now).
fn display_addr(address : String) -> String {
  if address.length() == 0 {
    "nobody"
  } else {
    address
  }
}

///|
/// How this host names itself in logs and errors.
fn PartitionHost::label(self : PartitionHost) -> String {
  "\{self.topic}[\{self.partition}]"
}

///|
/// Opens this node's log for the topic it hosts, creating it if
/// needed. Returns None when no topic is applied.
fn PartitionHost::open_log(self : PartitionHost) -> @log.SegmentedLog? {
  if self.topic.length() == 0 {
    return None
  }
  match open_partition_log(self.data_dir, self.topic, self.partition) {
    Ok(log) => Some(log)
    Err(e) => {
      note("warning: cannot open log for \{self.label()}: \{e}")
      None
    }
  }
}

///|
/// This node's log end, 0 when it holds nothing.
fn PartitionHost::leo(self : PartitionHost) -> Int64 {
  match self.open_log() {
    Some(log) => log.high_watermark()
    None => 0L
  }
}

///|
/// Am I the leader right now?
fn PartitionHost::is_leader(self : PartitionHost) -> Bool {
  self.leader_addr.length() > 0 && self.leader_addr == self.address
}

///|
/// Adopts the control plane's view of the partition. Becoming leader
/// seeds the progress ledger with every replica at its last known
/// progress (zero for a replica that has never reported) — which is
/// what keeps the high watermark honest: it cannot advance until the
/// replicas actually confirm, so a dead follower stalls it.
fn PartitionHost::adopt_view(
  self : PartitionHost,
  view : @client.PartitionView,
) -> Unit {
  let was_leader = self.is_leader()
  self.leader_addr = view.leader
  self.replicas = view.replicas
  self.nominated = view.nominated
  if self.is_leader() {
    if !was_leader || self.ledger is None {
      let progress : Array[@replica.ReplicaProgress] = []
      // carry over anything already known about replicas
      let known = self.ledger
      for address in view.replicas {
        let leo = if address == self.address {
          self.leo()
        } else {
          match known {
            Some(ledger) =>
              match ledger.leo_of(address) {
                Some(leo) => leo
                None => 0L
              }
            None => 0L
          }
        }
        progress.push(@replica.ReplicaProgress::{ spu: address, leo })
      }
      match @replica.ProgressLedger::new(self.address, progress) {
        Ok(ledger) => {
          self.ledger = Some(ledger)
          if !was_leader {
            self.caught_up = true
            note(
              "partition \{self.label()} is led by this node (\{self.address}), replica set \{view.replicas.length()}",
            )
          }
        }
        Err(e) => note("warning: cannot track replica progress: \{e}")
      }
    }
  } else if was_leader {
    note(
      "stepped down: \{view.leader} leads \{self.label()} now, this node follows",
    )
    self.ledger = None
    self.caught_up = false
  }
}

///|
/// Folds this node's own log end into the progress ledger. The
/// leader's LEO is not something anyone reports to it — it is a fact
/// about its own log — so it must be read back out of the log before
/// any watermark arithmetic happens. Skipping this makes a leader
/// advertise "leo 0" while holding data, and every follower then
/// concludes there is nothing to fetch.
fn PartitionHost::sync_leader_leo(self : PartitionHost) -> Unit {
  if !self.is_leader() {
    return
  }
  let leo = self.leo()
  match self.ledger {
    Some(ledger) =>
      match ledger.advance_leader(leo) {
        Ok(_) => ()
        Err(e) => note("warning: progress ledger: \{e}")
      }
    None => ()
  }
}

///|
/// One follower tick: make this node's log match the leader's.
///
/// The order matters. The follower asks the leader where its log
/// ends *first*, because that answer is the only authority for a
/// rejoin — and because a request phrased as "send me bytes from
/// offset N" cannot be answered at all when N is past the leader's
/// end, which is exactly the divergent case.
///
/// The rejoin rule is the project's own (the reference has no epoch
/// to compare tails with): **the leader's LEO wins**. A local tail
/// past it was never replicated, so it is cut — and the cut is
/// reported, never silent.
fn PartitionHost::replicate_once(
  self : PartitionHost,
  pump : () -> Unit,
) -> Unit {
  if self.is_leader() ||
    self.leader_addr.length() == 0 ||
    self.topic.length() == 0 {
    return
  }
  let log = match self.open_log() {
    Some(log) => log
    None => return
  }
  let my_leo = log.high_watermark()
  // The link is dialled once and reused: the handshake is the part
  // worth paying once, and with per-partition fan-out the connection
  // churn was the largest remaining per-tick cost (decision 30's
  // follow-up). A dropped link is redialled next round.
  if self.link is None {
    self.link = match SyncLink::connect(self.leader_addr) {
      Ok(link) => {
        note(
          "sync link to \{self.leader_addr} for \{self.label()} open (\{link.opens} dial(s) this incarnation)",
        )
        Some(link)
      }
      Err(e) => {
        if self.caught_up || !self.reported_failure {
          self.caught_up = false
          self.reported_failure = true
          note(
            "warning: replication from \{self.leader_addr} interrupted: \{e}",
          )
        }
        return
      }
    }
  }
  let link = match self.link {
    Some(link) => link
    None => return
  }
  // **One** request per tick per partition (P7): the pull *is* the
  // probe. Asking "where does your log end?" first cost an extra call
  // per partition, and with every node leading some partitions and
  // following others, the fan-out of those calls is what made three
  // nodes deafen each other. The reply to a pull already carries the
  // leader's end and high watermark, so it answers everything the
  // separate question did — including whether this replica has
  // diverged.
  let window = match
    sync_fetch(
      pump,
      link,
      self.topic,
      self.partition,
      my_leo,
      REPLICATION_BATCH,
    ) {
    Ok(window) => window
    Err(e) => {
      link.close()
      self.link = None
      if self.caught_up || !self.reported_failure {
        self.caught_up = false
        self.reported_failure = true
        note(
          "warning: replication from \{self.leader_addr} interrupted: \{e} (the sync link was dropped; the next round dials again)",
        )
      }
      return
    }
  }
  if window.log_end_offset < my_leo {
    // the leader's end is the authority: a local tail past it was never
    // replicated, so it is cut — and the cut is reported, never silent
    // the boundary form: the leader's end may land inside one of this
    // log's frames, and a partial batch is not a thing this log stores
    match log.truncate_to_boundary(window.log_end_offset) {
      Ok(report) => {
        // the leader's view of this replica just changed: the next ack
        // must be sent even if the number is unchanged
        self.last_acked = -1L
        note(
          "divergent tail: truncated \{self.label()} from \{my_leo} to \{window.log_end_offset} (dropped \{report.dropped_records} records, \{report.dropped_bytes} bytes)",
        )
      }
      Err(e) => {
        note("warning: cannot truncate divergent tail: \{e}")
        return
      }
    }
  } else if window.record_count > 0 {
    if window.base_offset != my_leo {
      note(
        "warning: leader offered \{self.label()} from \{window.base_offset} but this node ends at \{my_leo}; refusing to guess",
      )
      return
    }
    match log.append_raw(window.frames, window.record_count) {
      Ok(_) => ()
      Err(e) => {
        note("warning: cannot apply replicated frames: \{e}")
        return
      }
    }
  }
  // tell the leader how far this node has durably stored — but only
  // when that is news. Re-acking the same LEO every tick was a second
  // call per partition per tick for nothing.
  let acked = log.high_watermark()
  if acked == self.last_acked {
    return
  }
  match sync_ack(pump, link, self.topic, self.partition, self.address, acked) {
    Ok(_) => {
      self.last_acked = acked
      self.reported_failure = false
      if !self.caught_up {
        self.caught_up = true
        note(
          "replicating \{self.label()} from \{self.leader_addr}; caught up to \{acked}",
        )
      }
    }
    Err(e) => {
      link.close()
      self.link = None
      if self.caught_up {
        self.caught_up = false
        note(
          "warning: ack to \{self.leader_addr} failed: \{e} (the sync link was dropped)",
        )
      }
    }
  }
}

///|
/// How many records one replication round pulls. Bounded so a node
/// stays responsive (serving requests between rounds) and so a
/// freshly started follower does not try to swallow a whole log in
/// one gulp.
const REPLICATION_BATCH : Int = 512

///|
/// Asks the leader for raw frames from `from`.
fn sync_fetch(
  pump : () -> Unit,
  link : SyncLink,
  topic : String,
  partition : Int,
  from : Int64,
  max_records : Int,
) -> Result[@client.SyncResponse, String] {
  let request = @client.SyncRequest::{
    partition: @client.PartitionRef::{ topic, partition },
    from,
    max_records,
  }
  let payload = match
    link.call(
      pump,
      @client.CMD_SYNC_FETCH,
      @client.encode_sync_request(request),
      PEER_CALL_TIMEOUT_MS,
    ) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_sync_response(payload)
}

///|
/// Reports this node's log end to its leader and returns the leader's
/// watermarks.
fn sync_ack(
  pump : () -> Unit,
  link : SyncLink,
  topic : String,
  partition : Int,
  from : String,
  leo : Int64,
) -> Result[(Int64, Int64), String] {
  let ack = @client.SyncAck::{
    partition: @client.PartitionRef::{ topic, partition },
    from,
    leo,
  }
  let payload = match
    link.call(
      pump,
      @client.CMD_SYNC_ACK,
      @client.encode_sync_ack(ack),
      PEER_CALL_TIMEOUT_MS,
    ) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_offset_info(payload)
}

///|
/// Asks the control plane who leads a partition. Placement otherwise
/// arrives with the heartbeat reply; this is the *on-demand* path a
/// request handler uses when it meets a partition it has not heard
/// about yet — the window between "the control plane placed it" and
/// "the next heartbeat told this node".
fn ask_leader(
  sc_addr : String,
  topic : String,
  partition : Int,
) -> Result[@client.PartitionView, String] {
  let ref = @client.PartitionRef::{ topic, partition }
  let payload = match
    control_call(sc_addr, @client.CMD_LEADER, @client.encode_partition_ref(ref)) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_partition_view(payload)
}

///|
/// Leader-side: apply a follower's report and answer with the
/// watermarks that result. The ledger is where HW = min(LEO) lives
/// (core/replica); this function only moves the numbers.
fn PartitionHost::observe_follower(
  self : PartitionHost,
  ref : @client.PartitionRef,
  address : String,
  leo : Int64,
) -> Result[(Int64, Int64), String] {
  if self.topic != ref.topic || self.partition != ref.partition {
    return Err(
      "this node hosts \{self.label()}, not \{ref.topic}[\{ref.partition}]",
    )
  }
  let ledger = match self.ledger {
    Some(ledger) => ledger
    None => return Err("this node is not tracking progress for \{self.label()}")
  }
  match ledger.observe(address, leo) {
    Ok(_) => ()
    Err(e) => return Err("replica \{address}: \{e}")
  }
  let info = ledger.offset_info()
  Ok((info.high_watermark, info.log_end_offset))
}

///|
/// The topic the applied pipeline writes to, or "" when nothing is
/// applied. A node's *identity* is persistent; what it *hosts* comes
/// from the control plane's view of the world, which today is the
/// applied pipeline's topic (topic creation becomes a control-plane
/// verb in T24).
fn applied_topic(data_dir : String) -> String {
  match load_applied(data_dir) {
    Some(applied) => applied.spec.topic.name
    None => ""
  }
}

///|
/// Takes a partition the control plane has offered this node:
/// promotes itself, so the confirmation it sends back reports
/// something that already happened rather than asking permission.
/// That ordering is the reference's — the candidate decides it is
/// ready, and the control plane learns.
///
/// `core/replica.promote` owns the judgement about whether this node
/// may lead (it was offered the partition, it is not already leading),
/// so "no self-promotion without a nomination" has exactly one
/// implementation.
fn PartitionHost::take_nomination(
  self : PartitionHost,
  view : @client.PartitionView,
) -> Result[Unit, String] {
  if view.nominated != self.address {
    return Err(
      "the control plane offered \{view.nominated}, not \{self.address}",
    )
  }
  if self.address == view.leader {
    return Err("this node already leads the partition")
  }
  let state = @replica.ReplicaState::follower(self.address, view.leader)
  let nomination = @replica.Nomination::{
    partition_leader: view.leader,
    candidate: view.nominated,
  }
  let promoted = match @replica.promote(state, nomination) {
    Ok(promoted) => promoted
    Err(e) => return Err("\{e}")
  }
  if !(promoted.role is @replica.Leader) {
    return Err("promotion did not produce a leader")
  }
  self.leader_addr = self.address
  self.replicas = view.replicas
  self.caught_up = true
  // seed the ledger with every replica at zero except this node: the
  // others report their real positions within a heartbeat, and until
  // they do, a low watermark is the honest answer
  let progress : Array[@replica.ReplicaProgress] = []
  let replicas = if view.replicas.length() > 0 {
    view.replicas
  } else {
    [self.address]
  }
  for replica in replicas {
    let leo = if replica == self.address { self.leo() } else { 0L }
    progress.push(@replica.ReplicaProgress::{ spu: replica, leo })
  }
  match @replica.ProgressLedger::new(self.address, progress) {
    Ok(ledger) => self.ledger = Some(ledger)
    Err(e) => return Err("cannot track replica progress: \{e}")
  }
  note(
    "promoted: this node now leads \{self.topic} (the control plane offered it, this node accepted)",
  )
  Ok(())
}

///|
/// Reports a self-promotion to the control plane, which accepts it
/// only if this node was the one it offered the partition to.
fn confirm_leadership(
  sc_addr : String,
  topic : String,
  partition : Int,
  candidate : String,
) -> Result[Unit, String] {
  let confirmation = @client.Confirmation::{
    partition: @client.PartitionRef::{ topic, partition },
    candidate,
  }
  match
    control_call(
      sc_addr,
      @client.CMD_CONFIRM,
      @client.encode_confirmation(confirmation),
    ) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Every partition this node hosts (P7). A data node is a *set* of
/// hosts, not one partition: placement decides which ones, and the
/// control plane delivers that decision in the heartbeat reply.
///
/// Dropping a host never deletes data: the log stays on disk, so a
/// partition that comes back to this node resumes instead of
/// rebuilding. The ledger, though, is per-incarnation state and goes
/// with the host (the next adoption seeds it from the replicas).
struct HostTable {
  data_dir : String
  node_id : String
  address : String
  /// the topic the applied pipeline writes to ("" = none). Placement
  /// wins whenever a control plane declares this topic; when nobody
  /// declares it, this node is the only holder there is, and that is
  /// the degenerate placement `self_place` makes — the pre-P7 behavior,
  /// now written down instead of implied.
  mut applied_topic : String
  mut hosts : Array[PartitionHost]
}

///|
fn HostTable::new(
  data_dir : String,
  node_id : String,
  address : String,
) -> HostTable {
  HostTable::{ data_dir, node_id, address, applied_topic: "", hosts: [] }
}

///|
/// Holds partition 0 of the applied topic alone. Called only when no
/// control plane placement exists for it — a declared topic is always
/// the control plane's call, never this node's.
fn HostTable::self_place(self : HostTable, reason : String) -> Unit {
  if self.applied_topic.length() == 0 {
    return
  }
  match self.get(self.applied_topic, 0) {
    Some(_) => ()
    None => {
      let host = PartitionHost::new(
        self.data_dir,
        self.node_id,
        self.address,
        self.applied_topic,
        0,
      )
      host.adopt_view(@client.PartitionView::{
        leader: self.address,
        replicas: [self.address],
        nominated: "",
      })
      self.hosts.push(host)
      note(
        "hosting \{self.applied_topic}[0] alone (\{reason}); committed prefix = log end until a replica set says otherwise",
      )
    }
  }
}

///|
fn HostTable::find(self : HostTable, topic : String, partition : Int) -> Int? {
  for i, host in self.hosts {
    if host.topic == topic && host.partition == partition {
      return Some(i)
    }
  }
  None
}

///|
/// The host for a partition, or None when this node does not hold it.
fn HostTable::get(
  self : HostTable,
  topic : String,
  partition : Int,
) -> PartitionHost? {
  match self.find(topic, partition) {
    Some(i) => Some(self.hosts[i])
    None => None
  }
}

///|
/// Creates or updates the host for an assignment. An existing host
/// keeps its ledger across updates — progress is a fact about the
/// replicas, and re-seeding it every tick would make the high
/// watermark flap.
fn HostTable::adopt(
  self : HostTable,
  assignment : @client.AssignmentView,
  group_floor : Int64?,
) -> Unit {
  let view = @client.PartitionView::{
    leader: assignment.leader,
    replicas: assignment.replicas,
    nominated: assignment.nominated,
  }
  match self.find(assignment.topic, assignment.partition) {
    Some(i) => {
      let host = self.hosts[i]
      let leader_changed = host.leader_addr != assignment.leader
      host.adopt_view(view)
      host.group_floor = group_floor
      self.hosts[i] = host
      if leader_changed {
        note(
          "\{host.label()}: leader is now \{display_addr(assignment.leader)}",
        )
      }
    }
    None => {
      let host = PartitionHost::new(
        self.data_dir,
        self.node_id,
        self.address,
        assignment.topic,
        assignment.partition,
      )
      host.adopt_view(view)
      host.group_floor = group_floor
      self.hosts.push(host)
      note(
        "hosting \{host.label()} (leader \{assignment.leader}, \{assignment.replicas.length()} replica(s))",
      )
    }
  }
}

///|
/// The host for a partition, asking the control plane once when this
/// node has not heard about it yet. Only a partition this node is
/// actually assigned becomes a host — the control plane's answer is
/// the authority, this is just latency, not a second placement rule.
fn HostTable::ensure(
  self : HostTable,
  sc_addr : String,
  topic : String,
  partition : Int,
) -> PartitionHost? {
  match self.get(topic, partition) {
    Some(host) => return Some(host)
    None => ()
  }
  if sc_addr.length() == 0 {
    // nobody to ask: the applied topic is all this node knows, and it
    // is the only holder there is
    if topic == self.applied_topic && partition == 0 {
      self.self_place("no control plane configured")
      return self.get(topic, partition)
    }
    return None
  }
  match ask_leader(sc_addr, topic, partition) {
    Ok(view) => {
      if view.replicas.length() == 0 &&
        topic == self.applied_topic &&
        partition == 0 {
        // the control plane knows nothing about this topic (nobody
        // declared it), and this node runs the pipeline that writes it
        self.self_place("no declaration on the control plane")
        return self.get(topic, partition)
      }
      if !view.replicas.contains(self.address) {
        return None
      }
      // on-demand resolution has no floors to hand (that is the
      // heartbeat's job): the host keeps whatever it knew, and a host
      // that knew nothing keeps None — "no consumer" until told
      // otherwise, which is the conservative direction for retention
      self.adopt(
        @client.AssignmentView::{
          topic,
          partition,
          leader: view.leader,
          replicas: view.replicas,
          nominated: view.nominated,
        },
        self.get(topic, partition).map(fn(host) { host.group_floor }).flatten(),
      )
      self.get(topic, partition)
    }
    Err(e) => {
      if topic == self.applied_topic && partition == 0 {
        // the control plane is unreachable: fall back to holding the
        // pipeline's own partition rather than failing the request.
        // A divergence this creates is resolved by the rejoin rule
        // (the leader's LEO wins, and the cut is reported).
        self.self_place("control plane unreachable")
        return self.get(topic, partition)
      }
      note("warning: cannot resolve placement for \{topic}[\{partition}]: \{e}")
      None
    }
  }
}

///|
/// Drops hosts the control plane no longer assigns here.
fn HostTable::retain(
  self : HostTable,
  assignments : Array[@client.AssignmentView],
) -> Unit {
  let kept : Array[PartitionHost] = []
  for host in self.hosts {
    let mut still_assigned = false
    for a in assignments {
      if a.topic == host.topic && a.partition == host.partition {
        still_assigned = true
      }
    }
    if still_assigned {
      kept.push(host)
    } else {
      note("no longer assigned \{host.label()}; its log stays on disk")
    }
  }
  self.hosts = kept
}

///|
/// The per-partition progress this node reports upward.
fn HostTable::reports(self : HostTable) -> Array[@client.PartitionReport] {
  let out : Array[@client.PartitionReport] = []
  for host in self.hosts {
    out.push(@client.PartitionReport::{
      topic: host.topic,
      partition: host.partition,
      leo: host.leo(),
    })
  }
  out
}

///|
/// One housekeeping pass over every host: promote if this node is the
/// nominated candidate, then do this node's half of the partition —
/// a leader folds its own log end into the ledger, a follower pulls.
///
/// Nothing here asks the control plane anything: the assignment that
/// arrived with the heartbeat already carries leader, replicas and
/// nomination, so placement costs zero extra round trips.
fn HostTable::host_count(self : HostTable) -> Int {
  self.hosts.length()
}

///|
/// One partition's housekeeping round. Split out from the loop so the
/// caller can serve connections *between* partitions: with replication
/// fanning out per partition, a pass that never polled made peers wait
/// a whole deadline per partition (P7 measured this: three nodes, all
/// of them pulling at once, handshakes timing out).
///
/// It is also where storage housekeeping happens (P8/T46) — and only
/// on the **leader**: the committed prefix is the leader's answer, and a
/// follower keeps what it holds. The floor is that prefix (hw), so
/// retention can never delete data a replica still needs.
fn HostTable::tick_one(
  self : HostTable,
  sc_addr : String,
  i : Int,
  pump : () -> Unit,
) -> Unit {
  let host = self.hosts[i]
  if host.is_leader() {
    host.sync_leader_leo()
    if host.topic.length() > 0 {
      // The floor is the committed prefix, lowered by whatever
      // consumers still need (README 决策 31/32): the replicas bound it
      // from one side, the slowest group from the other, and deleting
      // data a consumer has not read yet is the one retention mistake
      // that cannot be undone.
      let committed = match host.ledger {
        Some(ledger) => ledger.offset_info().high_watermark
        None => 0L
      }
      let floor = match host.group_floor {
        Some(consumer_floor) =>
          if consumer_floor < committed {
            consumer_floor
          } else {
            committed
          }
        None => committed
      }
      match
        retain_partition(
          self.data_dir,
          host.topic,
          host.partition,
          floor,
          now_ms(),
        ) {
        Ok(_) => ()
        Err(e) => note("warning: \{e}")
      }
    }
  } else if host.topic.length() > 0 {
    if host.nominated == host.address && !host.is_leader() {
      let view = @client.PartitionView::{
        leader: host.leader_addr,
        replicas: host.replicas,
        nominated: host.nominated,
      }
      match host.take_nomination(view) {
        Ok(_) =>
          match
            confirm_leadership(
              sc_addr,
              host.topic,
              host.partition,
              host.address,
            ) {
            Ok(_) => ()
            Err(e) => note("warning: could not confirm leadership: \{e}")
          }
        Err(e) => note("warning: refused a nomination: \{e}")
      }
    }
    host.replicate_once(pump)
  }
  self.hosts[i] = host
}

///|
/// Every host once, in order — the form the tests and any caller
/// without connections to serve use.
fn HostTable::tick(
  self : HostTable,
  sc_addr : String,
  pump : () -> Unit,
) -> Unit {
  for i, _ in self.hosts {
    self.tick_one(sc_addr, i, pump)
  }
}

///|
/// The topic a produce payload names (its first field). Peeking beats
/// re-decoding: routing needs the name, the handler needs the batch.
fn peek_topic(payload : Bytes) -> Result[String, String] {
  let reader = @codec.Reader::new(payload)
  read_topic_name(reader)
}

///|
/// The partition a committed read names. The committed read reuses the
/// *unpartitioned* fetch payload (topic, from, max) — partitioning it
/// was deliberately left out when the read modes landed — so it means
/// partition 0, exactly as the plain FETCH does.
fn peek_committed_ref(payload : Bytes) -> Result[@client.PartitionRef, String] {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return Err(e)
  }
  Ok(@client.PartitionRef::{ topic, partition: 0 })
}

///|
/// The host for a partition, or the error reply to send instead: a
/// routing miss is answered, never guessed at.
fn host_or_error(
  hosts : HostTable,
  sc_addr : String,
  topic : String,
  partition : Int,
) -> Result[PartitionHost, (Int, Bytes)] {
  match hosts.ensure(sc_addr, topic, partition) {
    Some(host) => Ok(host)
    None =>
      Err(
        (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_WRONG_ROLE,
            "this node does not host \{topic}[\{partition}]",
          ),
        ),
      )
  }
}

///|
/// Writes belong to a partition's leader (P7): a follower accepts no
/// produce and says who the leader is, so a misdirected client can
/// correct itself instead of hanging.
fn require_leader(
  host : PartitionHost,
  topic : String,
  partition : Int,
) -> Result[Unit, (Int, Bytes)] {
  if host.is_leader() {
    return Ok(())
  }
  let leader = if host.leader_addr.length() > 0 {
    host.leader_addr
  } else {
    "unknown"
  }
  Err(
    (
      @client.CMD_ERR,
      @client.encode_error(
        @client.ERR_WRONG_ROLE,
        "writes for \{topic}[\{partition}] must go to its leader (\{leader})",
      ),
    ),
  )
}

///|
/// One request against a data node. Data commands behave exactly as
/// they do under `serve`; the replication commands are answered only
/// by the node that is actually the leader for the partition, so a
/// follower can never be mistaken for the source of truth.
fn dispatch_data_frame(
  frame : @client.Frame,
  data_dir : String,
  rules : RuleState,
  hosts : HostTable,
  sc_addr : String,
) -> (Int, Bytes) {
  match frame.cmd {
    @client.CMD_HELLO => {
      // the hub delivers the handshake frame to the same dispatcher the
      // data commands use (that is how `serve` works too), so the data
      // node answers it here rather than in a separate connection loop
      let (major, _minor) = match @client.decode_hello(frame.payload) {
        Ok(parts) => parts
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      if major != 1 {
        return (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_UNSUPPORTED_VERSION,
            "data node speaks major version 1 (frames v2); client sent \{major}",
          ),
        )
      }
      (@client.CMD_WELCOME, @client.encode_hello(1, 0))
    }
    @client.CMD_PRODUCE => {
      // the unpartitioned commands mean partition 0 of the topic they
      // name — true since P5, still true here
      let topic = match peek_topic(frame.payload) {
        Ok(topic) => topic
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      let host = match host_or_error(hosts, sc_addr, topic, 0) {
        Ok(host) => host
        Err(reply) => return reply
      }
      match require_leader(host, topic, 0) {
        Ok(_) => ()
        Err(reply) => return reply
      }
      let reply = dispatch_produce(frame.payload, data_dir)
      // the append just moved this node's log end; the ledger is what
      // the watermark arithmetic reads
      match hosts.get(topic, 0) {
        Some(fresh) => fresh.sync_leader_leo()
        None => ()
      }
      reply
    }
    @client.CMD_FETCH => {
      rules.sync(data_dir)
      dispatch_fetch(frame.payload, data_dir, rules)
    }
    @client.CMD_FETCH_COMMITTED => {
      let ref = match peek_committed_ref(frame.payload) {
        Ok(ref) => ref
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      let host = match host_or_error(hosts, sc_addr, ref.topic, ref.partition) {
        Ok(host) => host
        Err(reply) => return reply
      }
      // a committed read is a question for the leader: only it knows
      // how far the replicas have confirmed
      match require_leader(host, ref.topic, ref.partition) {
        Ok(_) => ()
        Err(reply) => return reply
      }
      rules.sync(data_dir)
      host.sync_leader_leo()
      let mut host = host
      match hosts.get(ref.topic, ref.partition) {
        Some(fresh) => host = fresh
        None => ()
      }
      let (hw, leo) = match host.ledger {
        Some(ledger) => {
          let info = ledger.offset_info()
          (info.high_watermark, info.log_end_offset)
        }
        None => (0L, host.leo())
      }
      dispatch_fetch_committed(frame.payload, data_dir, rules, hw, leo)
    }
    @client.CMD_PRODUCE_PARTITION => {
      let ref = match @client.decode_partitioned_produce(frame.payload) {
        Ok(parts) => {
          let (topic, partition, _frame) = parts
          @client.PartitionRef::{ topic, partition }
        }
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      let host = match host_or_error(hosts, sc_addr, ref.topic, ref.partition) {
        Ok(host) => host
        Err(reply) => return reply
      }
      match require_leader(host, ref.topic, ref.partition) {
        Ok(_) => ()
        Err(reply) => return reply
      }
      let (code, payload) = dispatch_produce_partition(frame.payload, data_dir)
      match hosts.get(ref.topic, ref.partition) {
        Some(fresh) => fresh.sync_leader_leo()
        None => ()
      }
      (code, payload)
    }
    @client.CMD_FETCH_PARTITION => {
      rules.sync(data_dir)
      let (code, payload) = dispatch_fetch_partition(
        frame.payload,
        data_dir,
        rules,
      )
      (code, payload)
    }
    @client.CMD_SYNC_FETCH => {
      let request = match @client.decode_sync_request(frame.payload) {
        Ok(request) => request
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      let host = match
        host_or_error(
          hosts,
          sc_addr,
          request.partition.topic,
          request.partition.partition,
        ) {
        Ok(host) => host
        Err(reply) => return reply
      }
      if !host.is_leader() {
        return (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_WRONG_ROLE,
            "this node does not lead \{host.label()}; ask \{host.leader_addr}",
          ),
        )
      }
      let log = match host.open_log() {
        Some(log) => log
        None =>
          return (
            @client.CMD_ERR,
            @client.encode_error(
              @client.ERR_STORAGE,
              "no log for \{host.label()}",
            ),
          )
      }
      host.sync_leader_leo()
      let partition = host
      // A pull from past this log's end is not an error: it is how a
      // diverged follower asks. Answering with an empty window at our
      // own end hands it the fact it needs (the leader's LEO is the
      // authority) instead of an error it can only retry (P7).
      let window = match log.read_raw(request.from, request.max_records) {
        Ok(window) => window
        Err(_) =>
          if request.from > log.high_watermark() {
            @log.RawWindow::{
              base_offset: request.from,
              record_count: 0,
              bytes: b"",
            }
          } else {
            return (
              @client.CMD_ERR,
              @client.encode_error(
                @client.ERR_STORAGE,
                "cannot read \{request.partition.topic}[\{request.partition.partition}] from \{request.from}",
              ),
            )
          }
      }
      let (hw, leo) = match partition.ledger {
        Some(ledger) => {
          let info = ledger.offset_info()
          (info.high_watermark, info.log_end_offset)
        }
        // no ledger yet (no follower has ever reported): the log end
        // is the only fact this node has, and claiming a watermark
        // equal to it would be a lie — report zero replicated prefix
        None => (0L, log.high_watermark())
      }
      let response = @client.SyncResponse::{
        base_offset: window.base_offset,
        record_count: window.record_count,
        high_watermark: hw,
        log_end_offset: leo,
        frames: window.bytes,
      }
      (@client.CMD_OK, @client.encode_sync_response(response))
    }
    @client.CMD_SYNC_ACK => {
      let ack = match @client.decode_sync_ack(frame.payload) {
        Ok(ack) => ack
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      let host = match
        host_or_error(
          hosts,
          sc_addr,
          ack.partition.topic,
          ack.partition.partition,
        ) {
        Ok(host) => host
        Err(reply) => return reply
      }
      match host.observe_follower(ack.partition, ack.from, ack.leo) {
        Ok((hw, leo)) => (@client.CMD_OK, @client.encode_offset_info(hw, leo))
        Err(e) =>
          (@client.CMD_ERR, @client.encode_error(@client.ERR_WRONG_ROLE, e))
      }
    }
    @client.CMD_SEGMENTS => {
      let ref = match @client.decode_partition_ref(frame.payload) {
        Ok(ref) => ref
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      match segment_view(data_dir, ref) {
        Ok(payload) => (@client.CMD_OK, payload)
        Err((code, message)) =>
          (@client.CMD_ERR, @client.encode_error(code, message))
      }
    }
    @client.CMD_OFFSET_INFO => {
      // the request optionally names a partition; empty means partition
      // 0 (the pre-P5 clients' shape, kept working)
      let asked = match @client.decode_partition_ref_opt(frame.payload) {
        Ok(asked) => asked
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_BAD_PAYLOAD, e),
          )
      }
      // every partition answers the same way now (P7): the host's
      // ledger is the watermark truth, and a host with no ledger yet
      // (no follower has ever reported) has a replicated prefix of
      // zero — claiming its log end would be a lie
      if asked.topic.length() == 0 {
        return (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_BAD_PAYLOAD,
            "offset info must name a topic: watermarks are per partition",
          ),
        )
      }
      let host = match
        host_or_error(hosts, sc_addr, asked.topic, asked.partition) {
        Ok(host) => host
        Err(reply) => return reply
      }
      host.sync_leader_leo()
      let (hw, leo) = match host.ledger {
        Some(ledger) => {
          let info = ledger.offset_info()
          (info.high_watermark, info.log_end_offset)
        }
        None => (0L, host.leo())
      }
      (@client.CMD_OK, @client.encode_offset_info(hw, leo))
    }
    @client.CMD_LEADER =>
      (
        @client.CMD_ERR,
        @client.encode_error(
          @client.ERR_WRONG_ROLE,
          "placement lives with the control plane (sc), not a data node",
        ),
      )
    other =>
      (
        @client.CMD_ERR,
        @client.encode_error(
          @client.ERR_UNKNOWN_COMMAND,
          "unknown command \{other}",
        ),
      )
  }
}

// ---------------------------------------------------------------------
// Placement (T22/T24 boundary): the control plane turns "these nodes
// exist" plus "these topics should exist" into "this partition lives
// here and is led by that node". The decision procedure is
// core/cluster's reconcile — pure, deterministic, and already tested;
// what lives here is only the wiring: reading the topic declarations,
// remembering the resulting state, and answering leader queries.

///|
/// The control plane's placement memory: the topic declarations it
/// last saw, and the cluster state core/cluster's reconcile produced
/// from them. Re-reading the declarations every tick is what makes
/// this level-triggered: an edited file is picked up without any
/// event, and an unchanged file produces no actions.
struct PlacementState {
  data_dir : String
  mut state : @cluster.ClusterState
  mut declarations : Array[ClusterMetadataTopic]
  /// addresses this control plane has ever assigned a partition to: an
  /// assigned node that is merely *down* stays in the replica set (it
  /// may come back and catch up), which is the difference between
  /// "the cluster lost a node" and "the cluster rebalanced"
  assigned : Array[String]
  /// pending elections: partition label -> the replica offered it. A
  /// nomination is a *state* here rather than a call, because the
  /// control plane must never dial a data node: both sides are
  /// single-threaded loops, and mutual calls let a busy node hang the
  /// cluster's brain. The candidate learns of its offer in the leader
  /// reply and confirms once it has taken the partition.
  mut nominated : Array[(String, String)]
  /// partitions already reported as having no eligible leader, so the
  /// condition is stated once rather than every tick
  mut reported_offline : Array[String]
  /// data nodes seen online at the last tick. The view consults it so
  /// that a leader which has gone silent is reported as *nobody*
  /// leading rather than as the address that used to
  mut online : Array[String]
}

///|
fn cluster_state_path(data_dir : String) -> String {
  "\{data_dir}/cluster-state.json"
}

///|
fn PlacementState::new(data_dir : String) -> PlacementState {
  let empty = PlacementState::{
    data_dir,
    state: @cluster.ClusterState::{ partitions: [] },
    declarations: [],
    assigned: [],
    nominated: [],
    reported_offline: [],
    online: [],
  }
  // assignments outlive the process: a control-plane restart must not
  // forget where partitions live, or a restart would look like a
  // rebalance and move replicas that were perfectly fine
  let bytes = match @fs.read_file(cluster_state_path(data_dir)) {
    Ok(bytes) => bytes
    Err(_) => return empty
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    _ => {
      note(
        "warning: \{cluster_state_path(data_dir)} is unreadable; starting from an empty placement",
      )
      return empty
    }
  }
  let obj = match json {
    Object(obj) => obj
    _ => {
      note("warning: cluster state must be a JSON object; ignoring it")
      return empty
    }
  }
  let partitions : Array[@cluster.ReplicaSet] = []
  match obj.get("partitions") {
    Some(Array(items)) =>
      for item in items {
        match parse_replica_set(item) {
          Some(rs) => partitions.push(rs)
          None => ()
        }
      }
    _ => ()
  }
  let state = @cluster.ClusterState::{ partitions, }
  let assigned : Array[String] = []
  for rs in state.partitions {
    for replica in rs.replicas {
      if !assigned.contains(replica) {
        assigned.push(replica)
      }
    }
  }
  PlacementState::{
    data_dir,
    state,
    declarations: [],
    assigned,
    nominated: [],
    reported_offline: [],
    online: [],
  }
}

///|
fn parse_replica_set(json : Json) -> @cluster.ReplicaSet? {
  let obj = match json {
    Object(obj) => obj
    _ => return None
  }
  let topic = match obj.get("topic") {
    Some(String(topic)) => topic
    _ => return None
  }
  let index = match obj.get("partition") {
    Some(Number(n)) => n.to_int()
    _ => return None
  }
  let leader = match obj.get("leader") {
    Some(String(leader)) => leader
    _ => ""
  }
  let replicas : Array[String] = []
  match obj.get("replicas") {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(address) => replicas.push(address)
          _ => ()
        }
      }
    _ => return None
  }
  if replicas.length() == 0 {
    return None
  }
  Some(@cluster.ReplicaSet::{
    partition: @cluster.PartitionId::{ topic, index },
    leader,
    replicas,
  })
}

///|
/// Writes the placement to disk. Best-effort but never silent: a
/// control plane that cannot persist its decisions says so, because
/// the next restart would otherwise quietly forget them.
fn PlacementState::save(self : PlacementState) -> Unit {
  let items : Array[Json] = []
  for rs in self.state.partitions {
    let replicas : Array[Json] = []
    for replica in rs.replicas {
      replicas.push(Json::string(replica))
    }
    let doc_map : Map[String, Json] = {}
    doc_map["topic"] = Json::string(rs.partition.topic)
    doc_map["partition"] = Json::number(rs.partition.index.to_double())
    doc_map["leader"] = Json::string(rs.leader)
    doc_map["replicas"] = Json::array(replicas)
    items.push(Json::object(doc_map))
  }
  let root_map : Map[String, Json] = {}
  root_map["partitions"] = Json::array(items)
  let text = Json::object(root_map).stringify(indent=2)
  let path = cluster_state_path(self.data_dir)
  match @fs.mkdirs(self.data_dir) {
    Ok(_) => ()
    Err(e) => {
      note("warning: cannot create \{self.data_dir}: \{e}")
      return
    }
  }
  match @fs.write_file(path, @utf8.encode(text[0:text.length()])) {
    Ok(_) => ()
    Err(e) => note("warning: cannot persist placement to \{path}: \{e}")
  }
}

///|
/// One reconcile tick: observe (online data nodes + declared topics),
/// decide (reconcile), record (apply_actions). Errors are reported
/// once per tick and never take the control plane down — a cluster
/// whose declarations are unsatisfiable (more replicas than nodes) is
/// a configuration to fix, not a crash.
fn PlacementState::tick(self : PlacementState, table : NodeTable) -> Unit {
  // declarations come from the metadata store: the same document the
  // `topic` verbs write, read fresh every tick, which is what makes an
  // operator's change take effect without any event
  let declarations = match list_topics(file_metadata_store(self.data_dir)) {
    Ok(topics) => topics
    Err(e) => {
      note("warning: cannot read topic declarations: \{e}")
      []
    }
  }
  // the pool is "everyone we have ever placed on" plus "everyone
  // present now": a node that goes down keeps its partitions (and so
  // keeps the high watermark honest), while a node that joins becomes
  // eligible to receive one
  let pool : Array[String] = []
  for address in self.assigned {
    pool.push(address)
  }
  for node in table.snapshot() {
    if node.role is Spu && !pool.contains(node.address) {
      pool.push(node.address)
    }
  }
  let spus : Array[@cluster.SpuSpec] = []
  for address in pool {
    spus.push(@cluster.SpuSpec::{ id: address, address })
  }
  let topics : Array[@cluster.TopicSpec] = []
  for decl in declarations {
    topics.push(@cluster.TopicSpec::{
      name: decl.name,
      partitions: decl.partitions,
      replication_factor: decl.replication_factor,
    })
  }
  let spec = @cluster.ClusterSpec::{ topics, spus }
  match @cluster.reconcile(self.state, spec) {
    Err(e) =>
      // a refused reconcile is a steady state, not an event storm:
      // only say it when the declarations changed
      if declarations.length() != self.declarations.length() {
        note("warning: cannot place partitions: \{e}")
      }
    Ok(actions) =>
      if actions.length() > 0 {
        self.state = @cluster.apply_actions(self.state, actions)
        for action in actions {
          match action {
            @cluster.PlacePartition(partition, replicas) => {
              for replica in replicas {
                if !self.assigned.contains(replica) {
                  self.assigned.push(replica)
                }
              }
              note(
                "placed \{partition.topic}[\{partition.index}] on \{replicas.length()} replica(s): \{format_addresses(replicas)}",
              )
            }
            @cluster.AssignLeader(partition, leader) =>
              note(
                "assigned leader of \{partition.topic}[\{partition.index}]: \{leader}",
              )
            @cluster.RemovePartition(partition) =>
              note("removed \{partition.topic}[\{partition.index}]")
          }
        }
        self.save()
      }
  }
  self.declarations = declarations
  // placement is settled; now the availability question: does every
  // partition still have a living leader?
  self.elect_fallen_leaders(table)
}

///|
/// Decides who should take a partition whose leader is gone, and
/// offers it to them.
///
/// Who deserves it: the **least lagging eligible replica**
/// (core/replica's `elect_candidate`, which knows the LRS rule and
/// excludes the vanished leader). Eligibility comes from each node's
/// reported LEO — the same numbers the leader used for its watermark,
/// so the election cannot disagree with replication about who was
/// furthest along. When nobody is eligible the partition has no
/// leader, and that steady state is reported once rather than every
/// tick.
///
/// The offer is recorded, not sent: the candidate reads it from the
/// leader reply and confirms after promoting itself. A control plane
/// that dialed data nodes could be blocked by a busy one.
fn PlacementState::elect_fallen_leaders(
  self : PlacementState,
  table : NodeTable,
) -> Unit {
  let online : Array[String] = []
  for node in table.snapshot() {
    if node.role is Spu {
      online.push(node.address)
    }
  }
  self.online = online
  for rs in self.state.partitions {
    let label = "\{rs.partition.topic}[\{rs.partition.index}]"
    if rs.leader.length() > 0 && online.contains(rs.leader) {
      continue // the leader is alive: nothing to decide
    }
    // build the ledger from what the nodes themselves reported, so
    // the election reads exactly the facts replication does
    let progress : Array[@replica.ReplicaProgress] = []
    for replica in rs.replicas {
      // the candidate weighting must read *this partition's* progress
      // (P7): a node that is far along on another partition is not
      // therefore a good candidate for this one
      let leo = table.leo_of(replica, rs.partition.topic, rs.partition.index)
      progress.push(@replica.ReplicaProgress::{ spu: replica, leo })
    }
    // the yardstick is the best *surviving* copy, not the vanished
    // leader's last number: measuring "too far behind" against a node
    // that no longer exists would call every survivor caught up
    let mut yardstick = rs.leader
    let mut best : Int64 = -1L
    for p in progress {
      if p.leo > best {
        best = p.leo
        yardstick = p.spu
      }
    }
    let ledger = match @replica.ProgressLedger::new(yardstick, progress) {
      Ok(ledger) => ledger
      Err(e) => {
        note("warning: cannot weigh candidates for \{label}: \{e}")
        continue
      }
    }
    let policy = @replica.LrsPolicy::{
      max_lag_records: @replica.DEFAULT_MAX_LAG,
    }
    match @replica.elect_candidate(ledger, policy, rs.leader) {
      Some(candidate) =>
        if online.contains(candidate) {
          let already = match self.nomination_of(label) {
            Some(current) => current == candidate
            None => false
          }
          if !already {
            self.set_nomination(label, candidate)
            note(
              "offering \{label} to \{candidate} (least lagging eligible replica; previous leader \{rs.leader} is gone)",
            )
          }
        }
      None =>
        if !self.reported_offline.contains(label) {
          self.reported_offline.push(label)
          note(
            "no eligible replica for \{label}: partition is offline (a replica too far behind has no vote)",
          )
        }
    }
  }
}

///|
fn PlacementState::nomination_of(
  self : PlacementState,
  label : String,
) -> String? {
  for pair in self.nominated {
    if pair.0 == label {
      return Some(pair.1)
    }
  }
  None
}

///|
fn PlacementState::set_nomination(
  self : PlacementState,
  label : String,
  candidate : String,
) -> Unit {
  let kept : Array[(String, String)] = []
  for pair in self.nominated {
    if pair.0 != label {
      kept.push(pair)
    }
  }
  kept.push((label, candidate))
  self.nominated = kept
}

///|
fn PlacementState::clear_nomination(
  self : PlacementState,
  label : String,
) -> Unit {
  let kept : Array[(String, String)] = []
  for pair in self.nominated {
    if pair.0 != label {
      kept.push(pair)
    }
  }
  self.nominated = kept
}

///|
/// Accepts a candidate's claim to a partition — but only if this
/// control plane was the one that offered it. That check is what
/// keeps "promotion requires a nomination" true end to end: a node
/// cannot talk its way into leadership, it can only report a
/// promotion that was already authorized.
fn PlacementState::confirm(
  self : PlacementState,
  topic : String,
  partition : Int,
  candidate : String,
) -> Result[Unit, String] {
  let label = "\{topic}[\{partition}]"
  match self.nomination_of(label) {
    None =>
      return Err(
        "no election was pending for \{label}; \{candidate} promoted itself without a nomination",
      )
    Some(expected) =>
      if expected != candidate {
        return Err("\{label} was offered to \{expected}, not \{candidate}")
      }
  }
  let updated : Array[@cluster.ReplicaSet] = []
  for rs in self.state.partitions {
    if rs.partition.topic == topic && rs.partition.index == partition {
      updated.push(@cluster.ReplicaSet::{
        partition: rs.partition,
        leader: candidate,
        replicas: rs.replicas,
      })
    } else {
      updated.push(rs)
    }
  }
  self.state = @cluster.ClusterState::{ partitions: updated }
  self.clear_nomination(label)
  let kept : Array[String] = []
  for seen in self.reported_offline {
    if seen != label {
      kept.push(seen)
    }
  }
  self.reported_offline = kept
  self.save()
  note("elected \{candidate} leader of \{label}")
  Ok(())
}

///|
/// The view of one partition: who leads it, who holds it, and who is
/// The partitions a node holds, with the view it needs to act on
/// each: leader, replica set, and any pending nomination. A node that
/// is not in a replica set is not assigned that partition, full stop.
///
/// The leader reported here is "" while its node is offline — the
/// nomination still travels, which is how a candidate learns to take
/// over.
fn PlacementState::assignments_for(
  self : PlacementState,
  address : String,
) -> Array[@client.AssignmentView] {
  let out : Array[@client.AssignmentView] = []
  for rs in self.state.partitions {
    if !rs.replicas.contains(address) {
      continue
    }
    let label = "\{rs.partition.topic}[\{rs.partition.index}]"
    let nominated = match self.nomination_of(label) {
      Some(candidate) => candidate
      None => ""
    }
    let leader = if self.online.contains(rs.leader) { rs.leader } else { "" }
    out.push(@client.AssignmentView::{
      topic: rs.partition.topic,
      partition: rs.partition.index,
      leader,
      replicas: rs.replicas,
      nominated,
    })
  }
  out
}

///|
/// being offered it. The offer rides along because the candidate has
/// to learn about its nomination somehow, and this is the one reply
/// every data node already asks for on every tick.
fn PlacementState::view(
  self : PlacementState,
  topic : String,
  partition : Int,
) -> @client.PartitionView {
  let label = "\{topic}[\{partition}]"
  let nominated = match self.nomination_of(label) {
    Some(candidate) => candidate
    None => ""
  }
  for rs in self.state.partitions {
    if rs.partition.topic == topic && rs.partition.index == partition {
      // a leader that has gone silent leads nothing: report nobody
      // (the nomination still travels, so a candidate can take over)
      let leader = if self.online.contains(rs.leader) { rs.leader } else { "" }
      return @client.PartitionView::{ leader, replicas: rs.replicas, nominated }
    }
  }
  @client.PartitionView::{ leader: "", replicas: [], nominated }
}

///|
fn format_addresses(addresses : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i, address in addresses {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(address)
  }
  sb.to_string()
}
