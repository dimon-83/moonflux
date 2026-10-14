// SPDX-License-Identifier: Apache-2.0
// The RUN LOG and the run reporter (P37-2).
//
// Two facts a run owes the platform, and the reason they are one file:
//
//   * the run's ID is `<task>@<revision>#<run-log offset>` — derived from the
//     log, never from a clock. A wall-clock id would make two runs of the same
//     task in the same millisecond indistinguishable, and it would make the id
//     unreproducible from the record of the run (the same reason nothing that
//     gates a build reads a clock here).
//   * the run's LIVENESS is a report to a broker/control plane. A run that
//     stopped on purpose says so; a run that is killed goes silent and is aged
//     out. Those are different facts and the platform shows them differently.
//
// Nothing here is written unless the runner was told where to report
// (`pipeline run --control <addr>`): adding a topic to someone's data dir
// unasked is the same mistake the state progress marker made in P36, and the
// example gate caught it then. A run nobody was told about is invisible, and
// that is stated rather than papered over.

// ---------------------------------------------------------------------
// Who is running (P37-2): the process id and the host. Both are facts the
// runner has and the platform wants; a run has NO address of its own (it
// accepts no connections), which is why the record carries these instead.
//
// Int32 at the boundary, explicitly: the new toolchain normalises C FFI types
// that way, and the C side is `int` (README decision 80).
// `cli_pid` is declared in main.mbt (the CLI already had a pid for its own
// diagnostics); only the host name is new here.

///|
#borrow(buf)
extern "C" fn cli_hostname(buf : Bytes, len : Int32) -> Int32 = "mf_cli_hostname"

///|
/// This process's id.
fn runner_pid() -> Int32 {
  cli_pid()
}

///|
/// This machine's name, or "-" when it cannot be learned (the record says so
/// rather than inventing a host).
fn runner_host() -> String {
  let buf : Bytes = Bytes::make(256, b'\x00')
  let n = cli_hostname(buf, 256)
  if n <= 0 {
    return "-"
  }
  @utf8.decode_lossy(buf[0:n])
}

///|
/// The topic a run's events land in. One per task: a run log is the record of
/// what a task has been doing, and that is exactly the thing an operator asks
/// for by task name.
fn run_log_topic(task : String) -> String {
  "\{task}.run-log"
}

///|
/// A run's event log. Writes go to the runner's own data dir, or through the
/// cluster when the runner was told where the control plane is — the same
/// one-writer rule the state topic follows (P36): a second writer into a data
/// dir a node replicates would leave that node's cached end stale.
struct RunLog {
  task : String
  /// Local append, or a cluster append, returning the offset the batch landed
  /// at (the run-start offset is the run's id).
  append : (String, Array[@protocol.Record]) -> Result[Int64, String]
  /// Held between events so the topic is opened once per run, not per batch.
  mut topic_opened : Bool
}

///|
/// Opens the run log for a task. `remote` is the cluster writer when the run
/// was pointed at a control plane and its data dir belongs to a node.
fn RunLog::open(
  task : String,
  append : (String, Array[@protocol.Record]) -> Result[Int64, String],
) -> RunLog {
  RunLog::{ task, append, topic_opened: false, }
}

///|
/// Appends one event. The KEY is the event kind (`run-start`, `batch`,
/// `run-stop`, `error`) and the VALUE is a JSON object, so the record is
/// self-describing for whatever reads it later — a console, a gate, or a human
/// with `consume`.
fn RunLog::event(
  self : RunLog,
  kind : String,
  detail : Map[String, Json],
) -> Result[Int64, String] {
  let topic = run_log_topic(self.task)
  let doc : Map[String, Json] = {}
  doc["event"] = Json::string(kind)
  doc["task"] = Json::string(self.task)
  for pair in detail {
    let (key, value) = pair
    doc[key] = value
  }
  let record = @protocol.Record::{
    timestamp: @env.now().reinterpret_as_int64(),
    key: @utf8.encode(kind),
    value: @utf8.encode(Json::object(doc).stringify()),
    headers: [],
  }
  (self.append)(topic, [record])
}

///|
/// The reporter: what the platform's run table learns from this process.
struct RunReporter {
  mut record : @client.RunRecord
  /// The control plane to report to, or None: a run nobody was told about does
  /// not report (and does not invent an address).
  control : String?
  link : PeerLink
  mut last_report_ms : Int64
  /// The last failure's text, so the log says it ONCE per distinct failure
  /// instead of once per heartbeat (the P11 rule for adoption failures).
  mut last_failure : String
}

///|
fn RunReporter::new(
  record : @client.RunRecord,
  control : String?,
  link : PeerLink,
) -> RunReporter {
  RunReporter::{ record, control, link, last_report_ms: 0L, last_failure: "", }
}

///|
/// How often a run reports itself. The same order as a node's heartbeat, and
/// for the same reason: the liveness window has to be several report periods
/// long, or a busy machine looks dead.
const RUN_REPORT_INTERVAL_MS : Int64 = 1000L

///|
/// Reports now, whatever the interval says (used at start and at the end).
fn RunReporter::report_now(
  self : RunReporter,
  progress : Int64,
  stopped : Bool,
) -> Unit {
  self.record = @client.RunRecord::{
    id: self.record.id,
    task: self.record.task,
    revision: self.record.revision,
    address: self.record.address,
    pid: self.record.pid,
    data_dir: self.record.data_dir,
    progress,
    stopped,
    state: if stopped {
      "stopped"
    } else {
      "running"
    },
  }
  let addr = match self.control {
    Some(addr) => addr
    None => return
  }
  let payload = @client.encode_run(self.record)
  match control_call_secure(addr, @client.CMD_RUN_REPORT, payload, self.link) {
    Ok(_) => self.last_failure = ""
    Err(e) =>
      // The run does NOT die because the platform is unreachable: the data
      // plane does not depend on being watched (docs/task-console.md §9). It
      // says so once, and the table will show it offline until it can report
      // again.
      if e != self.last_failure {
        warn("warning: run report to \\{addr} failed: \\{e}\\n")
        self.last_failure = e
      }
  }
}

///|
/// Reports at most once per interval: the loop this rides runs every 50-100ms,
/// and a round trip per iteration would be a tax on the data path (P13's
/// question — "does this make one round longer?" — answered by the interval).
fn RunReporter::heartbeat(
  self : RunReporter,
  now : Int64,
  progress : Int64,
) -> Unit {
  match self.control {
    None => return
    Some(_) => ()
  }
  if now - self.last_report_ms < RUN_REPORT_INTERVAL_MS {
    return
  }
  self.last_report_ms = now
  self.report_now(progress, false)
}

///|
/// The run's id, from the offset its run-start record landed at.
fn run_id_of(task : String, revision : Int64, base : Int64) -> String {
  "\{task}@\{revision}#\{base}"
}

///|
/// One run's session: its log and its reporter, so a loop takes ONE argument
/// and cannot update one without the other. The order matters and is the
/// objective's wording: the batch is recorded first (the run log is the run's
/// own truth), then the platform is told (liveness).
struct RunSession {
  log : RunLog
  reporter : RunReporter
}

///|
/// Records a batch and reports progress. A batch event that cannot be written
/// does not kill the run — the sink is the point — but it is said, once per
/// distinct failure.
fn RunSession::batch(self : RunSession, progress : Int64, now : Int64) -> Unit {
  let detail : Map[String, Json] = {}
  detail["progress"] = Json::number(progress.to_double())
  match self.log.event("batch", detail) {
    Ok(_) => ()
    Err(e) => warn("warning: run log append failed: \{e}\n")
  }
  self.reporter.heartbeat(now, progress)
}

///|
/// Says "still alive" without claiming anything happened. A long-running task
/// that is merely IDLE (a relay with nothing to relay) used to report nothing
/// at all, so the run registry's liveness window reaped it as `offline` — a live
/// process declared dead, which is the failure mode the registry exists to
/// prevent (measured in docker: an idle `restart: never` task went offline while
/// its child was still running). Not a batch, so no run-log event: "nothing
/// happened" is not work, and writing it as one would inflate every idle task's
/// log forever. The reporter throttles this on its own interval.
fn RunSession::idle(self : RunSession, now : Int64, progress : Int64) -> Unit {
  self.reporter.heartbeat(now, progress)
}

///|
/// The graceful ending: write `run-stop`, THEN tell the platform the run
/// stopped on purpose. A run that is killed instead never reaches this, which
/// is exactly how the two endings stay distinguishable.
fn RunSession::stop(
  self : RunSession,
  reason : String,
  progress : Int64,
) -> Unit {
  let detail : Map[String, Json] = {}
  detail["reason"] = Json::string(reason)
  detail["progress"] = Json::number(progress.to_double())
  match self.log.event("run-stop", detail) {
    Ok(_) => ()
    Err(e) => warn("warning: run log append failed: \{e}\n")
  }
  self.reporter.report_now(progress, true)
}

///|
/// Records an error the run survived (a refused batch, a sink failure). The
/// run's own record of what went wrong belongs next to its batches.
fn RunSession::failed(self : RunSession, what : String) -> Unit {
  let detail : Map[String, Json] = {}
  detail["detail"] = Json::string(what)
  match self.log.event("error", detail) {
    Ok(_) => ()
    Err(_) => ()
  }
}

///|
/// `moonflux run list --remote <broker|sc>`: what is running, where, and how
/// far. The run table lives in a BROKER or CONTROL PLANE — a data dir has no
/// table, and the message says that rather than printing an empty list, which
/// would look like "nothing is running" instead of "you asked the wrong one".
fn run_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let addr = match flags.get("remote") {
    Some(addr) => addr
    None =>
      fail(
        "a run table lives in a broker or control plane, not in a data dir; pass --remote <host:port>",
      )
  }
  let payload = match
    control_call_secure(addr, @client.CMD_RUN_LIST, b"", peer_link(flags)) {
    Ok(payload) => payload
    Err(e) => fail("run list: \{e}")
  }
  let runs = match @client.decode_runs(payload) {
    Ok(runs) => runs
    Err(e) => fail("run list: \{e}")
  }
  if runs.length() == 0 {
    println("no run is reporting to \{addr}")
    cli_exit(0)
  }
  for line in run_list_lines(runs) {
    println(line)
  }
  cli_exit(0)
}

///|
/// The `run` verb: watching runs, not changing them (changing what runs is
/// `pipeline run`, which the platform does not do on anyone's behalf).
fn cmd_run(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    usage()
  }
  match argv[0] {
    "list" => run_list(argv[1:argv.length()].to_owned())
    _ => usage()
  }
}
