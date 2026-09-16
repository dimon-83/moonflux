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
  // a deadline, not a wait: every node is a single-threaded loop, so
  // a busy peer must fail this call rather than block this node's
  // whole tick
  let conn = match
    @client.Conn::tcp_with_timeout(host, port, CONTROL_CALL_TIMEOUT_MS) {
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
  let partition = PartitionHost::new(data_dir, identity.id, "\{host}:\{actual}")
  partition.topic = applied_topic(data_dir)
  if partition.topic.length() > 0 {
    note("hosting topic \{partition.topic}")
  } else {
    note(
      "no pipeline applied yet: this node serves requests but hosts no topic",
    )
  }
  let mut last_report : Int64 = -1L
  let mut registered = false
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_data_connection(stream, data_dir, rules, partition)
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
          // refresh placement, then do this node's half of it: a
          // leader serves frames, a follower pulls them
          if partition.topic.length() > 0 {
            // a freshly applied pipeline can change which topic this
            // node hosts (node.json has no opinion on topics)
            let applied = applied_topic(data_dir)
            if applied.length() > 0 && applied != partition.topic {
              partition.topic = applied
              partition.ledger = None
              partition.leader_addr = ""
              partition.caught_up = false
              note("now hosting topic \{partition.topic}")
            }
            match ask_leader(sc_addr, partition.topic) {
              Ok(view) => {
                partition.adopt_view(view)
                // the control plane offers leadership by naming a
                // candidate; accepting means promoting ourselves and
                // then telling it (the reference's two-phase
                // election: nominating and confirming are different
                // acts, and neither alone makes a leader)
                if view.nominated == partition.address && !partition.is_leader() {
                  match partition.take_nomination(view) {
                    Ok(_) =>
                      match
                        confirm_leadership(
                          sc_addr,
                          partition.topic,
                          partition.address,
                        ) {
                        Ok(_) => ()
                        Err(e) =>
                          note("warning: could not confirm leadership: \{e}")
                      }
                    Err(e) => note("warning: refused a nomination: \{e}")
                  }
                }
              }
              Err(e) =>
                if partition.leader_addr.length() > 0 {
                  note("warning: cannot refresh placement: \{e}")
                }
            }
            partition.replicate_once()
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
  let store = file_metadata_store(data_dir)
  let placement = PlacementState::new(data_dir)
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_control_connection(stream, table, placement, store)
        let _ = stream.close()
      }
      Err(TimedOut) => ()
      Err(e) => fail("accept: \{e}")
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
  placement : PlacementState,
  store : MetadataStore,
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
  /// the topic this node was given, or "" when nothing is applied;
  /// mutable because a node learns it from the applied pipeline
  mut topic : String
  /// the address this node advertises to peers
  address : String
  /// this node's identity
  mut node_id : String
  /// leader-side progress ledger; only meaningful while leading
  mut ledger : @replica.ProgressLedger?
  /// who leads the partition right now ("" = nobody yet)
  mut leader_addr : String
  /// the addresses that hold the partition (from the control plane)
  mut replicas : Array[String]
  /// set once the follower has reported its first successful pull
  mut caught_up : Bool
}

///|
fn PartitionHost::new(
  data_dir : String,
  node_id : String,
  address : String,
) -> PartitionHost {
  PartitionHost::{
    data_dir,
    topic: "",
    address,
    node_id,
    ledger: None,
    leader_addr: "",
    replicas: [],
    caught_up: false,
  }
}

///|
/// Opens this node's log for the topic it hosts, creating it if
/// needed. Returns None when no topic is applied.
fn PartitionHost::open_log(self : PartitionHost) -> @log.SegmentedLog? {
  if self.topic.length() == 0 {
    return None
  }
  match open_topic_log(self.data_dir, self.topic) {
    Ok(log) => Some(log)
    Err(e) => {
      note("warning: cannot open log for \{self.topic}: \{e}")
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
              "partition \{self.topic} is led by this node (\{self.address}), replica set \{view.replicas.length()}",
            )
          }
        }
        Err(e) => note("warning: cannot track replica progress: \{e}")
      }
    }
  } else if was_leader {
    note(
      "stepped down: \{view.leader} leads \{self.topic} now, this node follows",
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
fn PartitionHost::replicate_once(self : PartitionHost) -> Unit {
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
  let (leader_hw, leader_leo) = match offset_info_of(self.leader_addr) {
    Ok(pair) => pair
    Err(e) => {
      if self.caught_up {
        self.caught_up = false
        note("warning: replication from \{self.leader_addr} interrupted: \{e}")
      }
      return
    }
  }
  if my_leo > leader_leo {
    match log.truncate_to(leader_leo) {
      Ok(report) =>
        note(
          "divergent tail: truncated \{self.topic} from \{my_leo} to \{leader_leo} (dropped \{report.dropped_records} records, \{report.dropped_bytes} bytes)",
        )
      Err(e) => {
        note("warning: cannot truncate divergent tail: \{e}")
        return
      }
    }
  } else if my_leo < leader_leo {
    let window = match
      sync_fetch(self.leader_addr, self.topic, my_leo, REPLICATION_BATCH) {
      Ok(window) => window
      Err(e) => {
        if self.caught_up {
          self.caught_up = false
          note(
            "warning: replication from \{self.leader_addr} interrupted: \{e}",
          )
        }
        return
      }
    }
    if window.record_count > 0 {
      if window.base_offset != my_leo {
        note(
          "warning: leader offered \{self.topic} from \{window.base_offset} but this node ends at \{my_leo}; refusing to guess",
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
  }
  let _ = leader_hw
  // tell the leader how far this node has durably stored
  let acked = log.high_watermark()
  match sync_ack(self.leader_addr, self.topic, self.address, acked) {
    Ok(_) =>
      if !self.caught_up {
        self.caught_up = true
        note(
          "replicating \{self.topic} from \{self.leader_addr}; caught up to \{acked}",
        )
      }
    Err(e) =>
      if self.caught_up {
        self.caught_up = false
        note("warning: ack to \{self.leader_addr} failed: \{e}")
      }
  }
}

///|
/// Asks a node for its watermark pair. Position-independent, so it is
/// also the question a rejoining replica can always ask.
fn offset_info_of(address : String) -> Result[(Int64, Int64), String] {
  let payload = match control_call(address, @client.CMD_OFFSET_INFO, b"") {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_offset_info(payload)
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
  leader_addr : String,
  topic : String,
  from : Int64,
  max_records : Int,
) -> Result[@client.SyncResponse, String] {
  let request = @client.SyncRequest::{
    partition: @client.PartitionRef::{ topic, partition: 0 },
    from,
    max_records,
  }
  let payload = match
    control_call(
      leader_addr,
      @client.CMD_SYNC_FETCH,
      @client.encode_sync_request(request),
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
  leader_addr : String,
  topic : String,
  from : String,
  leo : Int64,
) -> Result[(Int64, Int64), String] {
  let ack = @client.SyncAck::{
    partition: @client.PartitionRef::{ topic, partition: 0 },
    from,
    leo,
  }
  let payload = match
    control_call(
      leader_addr,
      @client.CMD_SYNC_ACK,
      @client.encode_sync_ack(ack),
    ) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }
  @client.decode_offset_info(payload)
}

///|
/// Asks the control plane who leads this node's partition.
fn ask_leader(
  sc_addr : String,
  topic : String,
) -> Result[@client.PartitionView, String] {
  let ref = @client.PartitionRef::{ topic, partition: 0 }
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
  topic : String,
  address : String,
  leo : Int64,
) -> Result[(Int64, Int64), String] {
  if self.topic != topic {
    return Err("this node hosts \{self.topic}, not \{topic}")
  }
  let ledger = match self.ledger {
    Some(ledger) => ledger
    None => return Err("this node is not tracking progress for \{topic}")
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
  candidate : String,
) -> Result[Unit, String] {
  let confirmation = @client.Confirmation::{
    partition: @client.PartitionRef::{ topic, partition: 0 },
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
/// The data-node connection handler: `serve`'s protocol plus the
/// replication commands. Kept beside `handle_connection` rather than
/// folded into it so that `serve` (a single process that owns its
/// data dir and belongs to no cluster) keeps its exact old behaviour —
/// every pre-P3 gate runs through that path.
fn handle_data_connection(
  stream : @net.TcpStream,
  data_dir : String,
  rules : RuleState,
  partition : PartitionHost,
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
          "data node speaks frame version \{@client.PROTOCOL_VERSION}",
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
        "handshake required: send HELLO first",
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
    let reply = dispatch_data_frame(frame, data_dir, rules, partition)
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
/// One request against a data node. Data commands behave exactly as
/// they do under `serve`; the replication commands are answered only
/// by the node that is actually the leader for the partition, so a
/// follower can never be mistaken for the source of truth.
fn dispatch_data_frame(
  frame : @client.Frame,
  data_dir : String,
  rules : RuleState,
  partition : PartitionHost,
) -> (Int, Bytes) {
  match frame.cmd {
    @client.CMD_PRODUCE => {
      let reply = dispatch_produce(frame.payload, data_dir)
      // the append just moved this node's log end; the ledger is
      // what the watermark arithmetic reads
      partition.sync_leader_leo()
      reply
    }
    @client.CMD_FETCH => {
      rules.sync(data_dir)
      dispatch_fetch(frame.payload, data_dir, rules)
    }
    @client.CMD_FETCH_COMMITTED => {
      // a committed read is a question for the leader: only it knows
      // how far the replicas have confirmed
      if !partition.is_leader() {
        return (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_WRONG_ROLE,
            "committed reads must go to the leader (\{partition.leader_addr})",
          ),
        )
      }
      rules.sync(data_dir)
      partition.sync_leader_leo()
      let (hw, leo) = match partition.ledger {
        Some(ledger) => {
          let info = ledger.offset_info()
          (info.high_watermark, info.log_end_offset)
        }
        None => (0L, partition.leo())
      }
      dispatch_fetch_committed(frame.payload, data_dir, rules, hw, leo)
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
      if !partition.is_leader() {
        return (
          @client.CMD_ERR,
          @client.encode_error(
            @client.ERR_WRONG_ROLE,
            "this node does not lead \{request.partition.topic}; ask \{partition.leader_addr}",
          ),
        )
      }
      let log = match partition.open_log() {
        Some(log) => log
        None =>
          return (
            @client.CMD_ERR,
            @client.encode_error(
              @client.ERR_STORAGE,
              "no log for \{request.partition.topic}",
            ),
          )
      }
      partition.sync_leader_leo()
      let window = match log.read_raw(request.from, request.max_records) {
        Ok(window) => window
        Err(e) =>
          return (
            @client.CMD_ERR,
            @client.encode_error(@client.ERR_STORAGE, "\{e}"),
          )
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
      match partition.observe_follower(ack.partition.topic, ack.from, ack.leo) {
        Ok((hw, leo)) => (@client.CMD_OK, @client.encode_offset_info(hw, leo))
        Err(e) =>
          (@client.CMD_ERR, @client.encode_error(@client.ERR_WRONG_ROLE, e))
      }
    }
    @client.CMD_OFFSET_INFO => {
      partition.sync_leader_leo()
      let (hw, leo) = match partition.ledger {
        Some(ledger) => {
          let info = ledger.offset_info()
          (info.high_watermark, info.log_end_offset)
        }
        None => (0L, partition.leo())
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
      let leo = match table.find_address(replica) {
        Some(entry) => entry.record.leo
        None => 0L
      }
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
