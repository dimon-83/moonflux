// SPDX-License-Identifier: Apache-2.0
// Control-plane high availability (P34): a lease decides which control plane
// is ACTIVE, and the metadata write path is fenced by it.
//
// The risk this answers is the first one in docs/production-readiness.md §3:
// one `sc` process holds the cluster's declarations in one file, and if it
// dies there is nobody to create topics, coordinate groups or nominate
// leaders.
//
// What this is, stated plainly, because an HA story that oversells itself is
// worse than none:
//
//   * **active/standby over a SHARED data directory** (a shared filesystem,
//     or a PVC that both processes mount). There is no quorum and no
//     consensus: the lease is a file with an expiry, so takeover needs only
//     that the standby can READ the shared directory.
//   * **fenced writes.** Every metadata write re-reads the lease and refuses
//     unless this process still holds it at the epoch it was granted. A
//     control plane that was paused long enough to lose the lease cannot
//     write declarations after it wakes up — it steps down instead. This is
//     what keeps a pause from becoming a split brain.
//   * **NOT a virtual address.** A standby takes over on a *different*
//     address, so nodes and clients must be pointed at the new one (a
//     fronting load balancer or VIP does that; this process does not move
//     addresses, and pretending otherwise would be the lie).
//   * **the standby serves nothing.** It answers every command with a named
//     refusal carrying the active's address, and it does NOT run the
//     housekeeping sweeps: a standby that swept liveness would move group
//     generations for members it never saw.
//
// Off by default (`sc` without `--ha` behaves exactly as it did), and
// announced at startup — the same rule the auth path follows: a mode nobody
// chose must not be a mode nobody can see.

///|
/// Where the lease lives: beside the metadata, on the shared directory.
pub fn lease_path(data_dir : String) -> String {
  "\{data_dir}/sc-lease.json"
}

///|
/// The lease as it is stored. `epoch` is the fencing token: it changes on
/// every takeover, and a writer that carries an older epoch is refused.
pub(all) struct ControlLease {
  /// The address of the active control plane, as it was given to `--listen`.
  holder : String
  /// Monotonic takeover counter. Never reused, never decreased.
  epoch : Int64
  /// Wall-clock milliseconds after which the lease is void. The holder
  /// refreshes it every tick; a standby waits for it to pass.
  expires_at_ms : Int64
} derive(Debug, Eq)

///|
/// Reads the lease. `Ok(None)` means "no lease file" (nobody has ever taken
/// it, so taking it is not a takeover). A file that does not parse is an
/// ERROR, not an empty lease: guessing who owns the control plane is exactly
/// how two of them end up writing declarations.
pub fn read_lease(data_dir : String) -> Result[ControlLease?, String] {
  let path = lease_path(data_dir)
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(_) => return Ok(None)
  }
  if bytes.length() == 0 {
    return Ok(None)
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("\{path} is not valid JSON: \{e}")
  }
  let obj = match json {
    Object(obj) => obj
    _ => return Err("\{path} must be a JSON object")
  }
  let holder = match obj.get("holder") {
    Some(String(holder)) => holder
    _ => return Err("\{path} has no holder")
  }
  let epoch = match obj.get("epoch") {
    Some(Number(n)) => n.to_int64()
    _ => return Err("\{path} has no epoch")
  }
  let expires_at_ms = match obj.get("expires_at_ms") {
    Some(Number(n)) => n.to_int64()
    _ => return Err("\{path} has no expires_at_ms")
  }
  Ok(Some(ControlLease::{ holder, epoch, expires_at_ms, }))
}

///|
/// Writes the lease atomically (temp + rename), like the metadata document
/// and for the same reason: a half-written lease is a wrong answer about who
/// owns the cluster.
pub fn write_lease(
  data_dir : String,
  lease : ControlLease,
) -> Result[Unit, String] {
  let path = lease_path(data_dir)
  let root : Map[String, Json] = {}
  root["holder"] = Json::string(lease.holder)
  root["epoch"] = Json::number(lease.epoch.to_double())
  root["expires_at_ms"] = Json::number(lease.expires_at_ms.to_double())
  let text = Json::object(root).stringify(indent=2)
  match @fs.mkdirs(data_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{data_dir}: \{e}")
  }
  // The temp file is per-WRITER, not per-path: two control planes sharing this
  // directory both write the lease (that is the whole point of the lease), and
  // a shared `sc-lease.json.tmp` means one of them renames it away while the
  // other is still writing — the second then fails with ENOENT and exits
  // (measured by the HA gate's first run, which started exactly that pair).
  let mine = sanitize_for_path(lease.holder)
  let tmp = "\{path}.tmp.\{mine}"
  match @fs.write_file(tmp, @utf8.encode(text[0:text.length()])) {
    Ok(_) => ()
    Err(e) => return Err("write \{tmp}: \{e}")
  }
  match @fs.rename(tmp, path) {
    Ok(_) => Ok(())
    Err(e) => Err("rename \{tmp} -> \{path}: \{e}")
  }
}

///|
/// What this process is, according to the lease it just looked at.
pub(all) enum LeaseRole {
  /// We hold it (or just took it).
  Active
  /// Someone else holds it and it has not expired.
  Standby(String)
  /// We used to hold it and someone else has it now: reported once, so the
  /// step-down is visible in the log rather than inferred from behaviour.
  SteppedDown(String)
} derive(Debug, Eq)

///|
/// The lease holder's state machine. One instance per `sc` process; `step`
/// is called once per event-loop round, before any command is served, so a
/// command in that round sees the lease as of that round.
pub(all) struct LeaseKeeper {
  data_dir : String
  /// The address this process was told to listen on — its identity in the
  /// lease.
  addr : String
  /// How long a grant lasts. Longer than a few event-loop rounds (so a busy
  /// loop does not lose it) and short enough that a dead active is replaced
  /// in seconds.
  lease_ms : Int64
  /// Whether this process currently holds the lease. Read by the command
  /// path; written only by `step`.
  active : Ref[Bool]
  /// The epoch we hold, or -1 when we hold nothing.
  epoch : Ref[Int64]
  /// True once we have reported a step-down for the current rival, so the
  /// log gets one line per event instead of one per round.
  reported_stepdown : Ref[Bool]
}

///|
pub fn LeaseKeeper::new(
  data_dir : String,
  addr : String,
  lease_ms : Int64,
) -> LeaseKeeper {
  LeaseKeeper::{
    data_dir,
    addr,
    lease_ms,
    active: Ref::new(false),
    epoch: Ref::new(-1L),
    reported_stepdown: Ref::new(false),
  }
}

///|
pub fn LeaseKeeper::is_active(self : LeaseKeeper) -> Bool {
  self.active.val
}

///|
/// One round of the lease protocol. Returns what happened so the caller can
/// log transitions and decide whether to run housekeeping.
pub fn LeaseKeeper::step(
  self : LeaseKeeper,
  now : Int64,
) -> Result[LeaseRole, String] {
  let existing = match read_lease(self.data_dir) {
    Ok(existing) => existing
    Err(e) => return Err(e)
  }
  let holder = match existing {
    Some(lease) => lease.holder
    None => ""
  }
  let epoch = match existing {
    Some(lease) => lease.epoch
    None => 0L
  }
  let expired = match existing {
    Some(lease) => lease.expires_at_ms <= now
    None => true
  }
  let mine = holder == self.addr
  if mine || expired {
    // renew (mine) or take over (expired or absent). A takeover from someone
    // else bumps the epoch; a renewal keeps it. Bumping on takeover is what
    // makes a writer from before the takeover refuse itself.
    let next_epoch = if mine { epoch } else { epoch + 1L }
    let lease = ControlLease::{
      holder: self.addr,
      epoch: next_epoch,
      expires_at_ms: now + self.lease_ms,
    }
    match write_lease(self.data_dir, lease) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    self.active.val = true
    self.epoch.val = next_epoch
    self.reported_stepdown.val = false
    return Ok(Active)
  }
  // someone else holds it
  self.active.val = false
  if self.epoch.val >= 0L {
    self.epoch.val = -1L
    if !self.reported_stepdown.val {
      self.reported_stepdown.val = true
      return Ok(SteppedDown(holder))
    }
  }
  Ok(Standby(holder))
}

///|
/// The metadata store an ACTIVE control plane writes through: every save
/// re-reads the lease and refuses unless this process still holds it at the
/// epoch it was granted.
///
/// The check-then-write window is real and is bounded by the lease: a
/// process cannot lose the lease between the check and the rename without
/// the lease expiring in between, which takes `lease_ms`. That is the
/// assumption this design rests on, and it is stated here rather than
/// implied by silence.
pub fn fenced_metadata_store(
  data_dir : String,
  keeper : LeaseKeeper,
) -> MetadataStore {
  let inner = file_metadata_store(data_dir)
  MetadataStore::{
    load: fn() { (inner.load)() },
    save: fn(metadata) {
      let current = match read_lease(data_dir) {
        Ok(current) => current
        Err(e) =>
          return Err(
            Conflict(
              "refusing to write: the lease is unreadable (\{e}), and guessing is how two control planes write at once",
            ),
          )
      }
      match current {
        None =>
          Err(
            Conflict(
              "refusing to write: there is no lease on this data dir; this control plane is not active",
            ),
          )
        Some(lease) =>
          if lease.holder != keeper.addr {
            Err(
              Conflict(
                "refusing to write: control plane \{lease.holder} holds the lease (epoch \{lease.epoch}); this one is \{keeper.addr}",
              ),
            )
          } else if lease.epoch != keeper.epoch.val {
            Err(
              Conflict(
                "refusing to write: the lease epoch is \{lease.epoch}, this control plane holds \{keeper.epoch.val}",
              ),
            )
          } else if lease.expires_at_ms <= now_ms() {
            Err(
              Conflict(
                "refusing to write: this control plane's lease expired at \{lease.expires_at_ms}",
              ),
            )
          } else {
            (inner.save)(metadata)
          }
      }
    },
  }
}

///|
/// The payload a standby replies with. It names the active address, because
/// the only useful thing a refusal can do for the caller is tell it where to
/// go — the same shape the data plane uses for a non-leader write.
pub fn standby_message(data_dir : String) -> String {
  match read_lease(data_dir) {
    Ok(Some(lease)) =>
      "this control plane is standby; the active one is \{lease.holder} (epoch \{lease.epoch})"
    Ok(None) =>
      "this control plane is standby and no lease is held; no active control plane is reachable"
    Err(e) => "this control plane is standby and the lease is unreadable: \{e}"
  }
}

///|
/// A lease holder's address, made safe to put in a filename. The address is
/// `host:port`; the colon (and any IPv6 brackets) cannot appear in a path
/// component on every platform, and a temp file that collides is a temp file
/// two writers fight over.
fn sanitize_for_path(text : String) -> String {
  let out = StringBuilder::new()
  for ch in text {
    match ch {
      ':' | '/' | '[' | ']' | '*' | '?' | '"' | '<' | '>' | '|' =>
        out.write_char('_')
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}
