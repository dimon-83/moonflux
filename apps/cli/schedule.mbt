// SPDX-License-Identifier: Apache-2.0
// The control plane's SCHEDULING loop (P37-5b, decision 100).
//
// `target` (decision 97) is a task saying where it wants to run. This file is
// the other half: the control plane that READS those declarations, decides who
// actually gets each task, and says what it decided — including when it could
// not decide anything at all.
//
// Three facts this file keeps, and the order matters:
//
//   1. DESIRED  — the cluster's task set document (what should run, and where
//      it asked to run). The control plane already owns this (P11/P37).
//   2. ACTUAL   — the run table (what IS running). Also already owned.
//   3. CAPACITY — which workers exist at all. This was the missing one, and it
//      is why a runner now beats: a worker with nothing assigned to it has no
//      run to report, so without a beat the control plane cannot tell "no
//      worker" from "a worker that is idle on purpose".
//
// The loop is a RECONCILIATION, not a command: every tick recomputes the whole
// table from those three facts. Nothing here dials a worker (decision 20: the
// control plane never calls a data node) — the placement rides the worker's own
// beat, which is the same channel partition placement has always used.
//
// The rule that makes it honest: a task the control plane cannot place is
// PENDING and says WHY, in the table, forever. A scheduler that silently drops
// an unplaceable task is indistinguishable from one that never saw it.

///|
/// One worker as the control plane sees it. Only its id and its clock: the
/// address and data dir a beat carries are said in the registration log line
/// and never needed again — nothing here dials a worker (decision 20).
struct WorkerEntry {
  id : String
  mut last_seen_ms : Int64
}

///|
/// Who is available to take work. Liveness is DERIVED from beats and the same
/// window the node table uses: "silent" means one thing across this whole
/// control plane (P37-2's rule, applied to capacity).
struct WorkerRegistry {
  mut entries : Array[WorkerEntry]
  timeout_ms : Int64
}

///|
fn WorkerRegistry::new(timeout_ms : Int64) -> WorkerRegistry {
  WorkerRegistry::{ entries: [], timeout_ms, }
}

///|
/// A beat: the first one registers, every later one refreshes the clock.
/// Returns true when this is a worker the registry had not seen.
fn WorkerRegistry::observe(
  self : WorkerRegistry,
  id : String,
  now : Int64,
) -> Bool {
  for entry in self.entries {
    if entry.id == id {
      entry.last_seen_ms = now
      return false
    }
  }
  self.entries.push(WorkerEntry::{ id, last_seen_ms: now, })
  true
}

///|
/// Ages out silent workers. Dropping them is what makes their tasks
/// REASSIGNABLE: the next reconciliation cannot place work on a worker that is
/// no longer in the table, so "its owner died" needs no special case.
fn WorkerRegistry::sweep(self : WorkerRegistry, now : Int64) -> Array[String] {
  let kept : Array[WorkerEntry] = []
  let gone : Array[String] = []
  for entry in self.entries {
    if now - entry.last_seen_ms >= self.timeout_ms {
      gone.push(entry.id)
    } else {
      kept.push(entry)
    }
  }
  self.entries = kept
  gone
}

///|
/// The live workers' ids, in id order. The ORDER is part of the contract: the
/// placement rule breaks ties by "lowest id", so a placement is a pure
/// function of (live worker set, task list) — the same inputs always give the
/// same answer, which is what keeps a task from flapping between two workers
/// on consecutive ticks.
fn WorkerRegistry::live_ids(self : WorkerRegistry) -> Array[String] {
  let out : Array[String] = []
  for entry in self.entries {
    out.push(entry.id)
  }
  insert_sorted_strings(out)
  out
}

///|
/// Insertion sort in place: worker sets are small (one entry per runner a
/// cluster runs).
fn insert_sorted_strings(items : Array[String]) -> Unit {
  for i = 1; i < items.length(); i = i + 1 {
    let mut j = i
    while j > 0 && items[j - 1] > items[j] {
      let tmp = items[j - 1]
      items[j - 1] = items[j]
      items[j] = tmp
      j = j - 1
    }
  }
}

///|
/// The reconciliation table, and the memory it needs to tell an EVENT from a
/// STATE: "worker A is gone, this task moved to B" is a sentence, while "B owns
/// it" is just the current answer. Only the first deserves a log line.
struct Scheduler {
  mut rows : Array[@client.ScheduleRow]
  /// task -> owner as of the last tick, so a change is noticed once.
  owners : Map[String, String]
  /// Set once the control plane has a task set at all, so a worker can tell
  /// "run nothing" from "I have no opinion" (see WorkerPlacement).
  mut has_set : Bool
  /// The task set's revision at the last tick, echoed to every worker in its
  /// placement reply. The runner keys its document adoption on this number —
  /// the same pull-on-revision-change contract a data node has (P11).
  mut revision : Int64
}

///|
fn Scheduler::new() -> Scheduler {
  Scheduler::{ rows: [], owners: {}, has_set: false, revision: 0L, }
}

///|
/// Recomputes the whole table from the three facts. Cheap on purpose (one
/// entry per task a cluster runs) because it runs on the housekeeping tick AND
/// before every placement reply — a worker's beat must not have to wait for
/// the next tick to learn what it should be running.
fn Scheduler::tick(
  self : Scheduler,
  document : String,
  revision : Int64,
  workers : WorkerRegistry,
  running : Array[String],
) -> Unit {
  self.has_set = document.length() > 0
  self.revision = revision
  let live = workers.live_ids()
  let tasks = match parse_task_set_text(document, "the cluster's task set") {
    Ok(set) => set.tasks
    // A set nobody can read reconciles to nothing, and says so: the publish
    // path already refused such a document, so reaching here means the file
    // was changed underneath the control plane (P37-1b's故障注入 shape).
    Err(e) => {
      self.rows = []
      note("warning: cannot reconcile the cluster task set: \{e}")
      return
    }
  }
  let load : Map[String, Int32] = {}
  for id in live {
    load[id] = 0
  }
  let rows : Array[@client.ScheduleRow] = []
  // Pinned tasks are placed FIRST: a pin is a declaration, and it must not
  // lose its worker to a floating task that happened to be sorted earlier.
  for task in tasks {
    match task.target {
      None | Some("any") => ()
      Some(_) => rows.push(place(task, live, load, running))
    }
  }
  for task in tasks {
    match task.target {
      Some(t) if t != "any" => ()
      _ => rows.push(place(task, live, load, running))
    }
  }
  self.rows = rows
  self.report_changes(rows)
}

///|
/// Places ONE task: decides its owner (if any) and what is actually happening
/// to it. Returns the row rather than mutating, because the two passes above
/// build the table in placement order and then it is sorted for display. A
/// pure function of its arguments — the same reason placement does not flap.
fn place(
  task : TaskDoc,
  live : Array[String],
  load : Map[String, Int32],
  running : Array[String],
) -> @client.ScheduleRow {
  let target = match task.target {
    Some(t) => t
    None => "any"
  }
  if !task.enabled {
    return @client.ScheduleRow::{
      task: task.name,
      target,
      owner: "",
      state: "disabled",
      reason: "not desired: the task set says enabled=false",
    }
  }
  let owner = match task.target {
    // A PIN is a declaration, not a preference: the control plane does not
    // move a pinned task to a different worker when its target is gone.
    // Moving it would be the control plane deciding better than the operator
    // who wrote the pin, and it would look identical to a correct placement.
    Some(t) if t != "any" =>
      if contains_string(live, t) {
        Some(t)
      } else {
        None
      }
    // Floating work goes to the least-loaded live worker, ties broken by the
    // lowest id (live is in id order), so the answer is stable.
    _ => least_loaded(live, load)
  }
  match owner {
    None =>
      @client.ScheduleRow::{
        task: task.name,
        target,
        owner: "",
        state: "pending",
        reason: match task.target {
          Some(t) if t != "any" =>
            "target worker \{t} has no live runner (a pin is a declaration: not reassigned)"
          _ => "no live worker to run it"
        },
      }
    Some(id) => {
      load[id] = match load.get(id) {
        Some(n) => n + 1
        None => 1
      }
      let state = if contains_string(running, task.name) {
        "running"
      } else {
        // desired says it should run, a worker owns it, nothing is reporting
        // yet: that gap is the point of the table, and it is not silence
        "assigned"
      }
      @client.ScheduleRow::{
        task: task.name,
        target,
        owner: id,
        state,
        reason: "",
      }
    }
  }
}

///|
/// The least-loaded live worker, ties by lowest id (live is already sorted).
fn least_loaded(live : Array[String], load : Map[String, Int32]) -> String? {
  let mut best : String? = None
  let mut best_load = 0
  for id in live {
    let current = match load.get(id) {
      Some(n) => n
      None => 0
    }
    match best {
      None => {
        best = Some(id)
        best_load = current
      }
      // strictly less, so the FIRST (lowest id) worker wins a tie
      Some(_) =>
        if current < best_load {
          best = Some(id)
          best_load = current
        }
    }
  }
  best
}

///|
/// Says out loud when a task changed hands — the "its owner died, so it moved"
/// event. A task that only just appeared is not a reassignment and is not
/// logged here; the runner says that when it starts the child.
fn Scheduler::report_changes(
  self : Scheduler,
  rows : Array[@client.ScheduleRow],
) -> Unit {
  for row in rows {
    let previous = self.owners.get(row.task)
    let now_owner = if row.owner.length() == 0 { None } else { Some(row.owner) }
    match (previous, now_owner) {
      (Some(old), Some(new)) =>
        if old != new {
          note(
            "task \{row.task}: worker \{old} no longer holds it; assigned to \{new}",
          )
        }
      (Some(old), None) =>
        note(
          "task \{row.task}: worker \{old} no longer holds it and no live worker can take it (pending)",
        )
      (None, Some(_)) => ()
      (None, None) => ()
    }
    match now_owner {
      Some(id) => self.owners[row.task] = id
      // a task that lost its owner is FORGOTTEN here on purpose: if it comes
      // back later that is a fresh assignment, not a move
      None => self.owners.remove(row.task)
    }
  }
}

///|
/// What one worker should run, for the reply to its beat. The revision rides
/// along so the worker can pull the document exactly when it moved (P11's
/// pull-on-revision-change), not on a timer.
fn Scheduler::placement_for(
  self : Scheduler,
  worker : String,
) -> @client.WorkerPlacement {
  let tasks : Array[String] = []
  for row in self.rows {
    if row.owner == worker && row.state != "disabled" {
      tasks.push(row.task)
    }
  }
  @client.WorkerPlacement::{
    has_set: self.has_set,
    revision: self.revision,
    tasks,
  }
}

///|
/// One tab-separated line per task (the shape `topic list` and `run list` use,
/// so `cut -f1` and `grep` work in a gate).
fn schedule_list_lines(rows : Array[@client.ScheduleRow]) -> Array[String] {
  let out : Array[String] = []
  for row in rows {
    let owner = if row.owner.length() == 0 { "-" } else { row.owner }
    let reason = if row.reason.length() == 0 { "-" } else { row.reason }
    out.push(
      "\{row.task}\ttarget=\{row.target}\towner=\{owner}\tstate=\{row.state}\treason=\{reason}",
    )
  }
  out
}

///|
/// `moonflux task schedule --remote <sc>`: desired against actual, one row per
/// task. Like `run list`, the table lives in a control plane — a data dir has
/// no scheduler, and the message says that instead of printing an empty list
/// that looks like "everything is fine".
fn schedule_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let addr = match flags.get("remote") {
    Some(addr) => addr
    None =>
      fail(
        "the scheduling table lives in a control plane, not in a data dir; pass --remote <host:port>",
      )
  }
  let payload = match
    control_call_secure(addr, @client.CMD_SCHEDULE_LIST, b"", peer_link(flags)) {
    Ok(payload) => payload
    Err(e) => fail("task schedule: \{e}")
  }
  let rows = match @client.decode_schedule_rows(payload) {
    Ok(rows) => rows
    Err(e) => fail("task schedule: \{e}")
  }
  if rows.length() == 0 {
    println("no task set is applied on \{addr} (nothing to schedule)")
    cli_exit(0)
  }
  for line in schedule_list_lines(rows) {
    println(line)
  }
  cli_exit(0)
}

///|
/// Linear membership: every list this file walks is one entry per task or per
/// worker.
fn contains_string(items : Array[String], needle : String) -> Bool {
  for item in items {
    if item == needle {
      return true
    }
  }
  false
}
