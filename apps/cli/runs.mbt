// SPDX-License-Identifier: Apache-2.0
// The RUN table (P37-2): what the platform knows about what is running.
//
// A run is a process executing one applied task. The platform does not start or
// stop it — a runner (or a container orchestrator) does — but "is my task
// running, where, and how far" must be answerable, and before this it was not:
// `pipeline run` had zero REGISTER/HEARTBEAT traffic, so the only answer was to
// guess at processes.
//
// The distinction this file exists for: a run that STOPPED ON PURPOSE and a run
// that was KILLED are different facts, and a platform that cannot tell them
// apart will report a crashed task as healthy until someone notices.
//
//   * the runner's last report carries `stopped` -> the entry keeps that state
//     forever (nothing reaps a deliberate stop);
//   * a run that goes SILENT -> the same sweep that ages out nodes marks it
//     offline, and the entry records that it was reaped, not stopped.
//
// Both are visible, neither is silent, and neither is inferred from a clock in
// the kernel: the sweep takes `now` from the host, as every other timeout here
// does.

///|
/// Run states as the platform reports them. `Offline` is DERIVED (silence past
/// the liveness window), which is why it is not something a runner can claim.
pub(all) enum RunState {
  Running
  Stopped
  Offline
} derive(Debug, Eq, Show)

///|
/// One run's row.
struct RunEntry {
  record : @client.RunRecord
  /// When this run FIRST reported. With `last_seen_ms` it gives the run's
  /// lifespan, which is what tells "died after hours" apart from "died again,
  /// immediately" — the difference between a crash and a restart storm.
  first_seen_ms : Int64
  last_seen_ms : Int64
  mut state : RunState
}

///|
/// The table: small on purpose (runs per cluster, not records).
struct RunTable {
  entries : Array[RunEntry]
  timeout_ms : Int64
  /// How many entries the sweep has ever moved to offline. A COUNTER, because
  /// "a run died" is an event an operator wants to see even after the entry is
  /// forgotten.
  mut reaped : Int64
  /// How many settled entries have been evicted to stay under `cap`. A counter
  /// for the same reason as `reaped`: the release is reported.
  mut evicted : Int64
  /// The ceiling on remembered runs. Without it this table grew by one entry per
  /// run the cluster had EVER seen — unbounded memory, and every sweep and
  /// listing walking a longer array, which is exactly the "does this make one
  /// turn of the event loop longer" question P13 says to ask before adding
  /// periodic work (iron rule 1, AGENT.md). Runs per cluster are few; a
  /// long-lived control plane is not.
  cap : Int32
}

///|
const RUN_TABLE_CAP : Int32 = 1024

///|
fn RunTable::new(timeout_ms : Int64) -> RunTable {
  RunTable::{
    entries: [],
    timeout_ms,
    reaped: 0L,
    evicted: 0L,
    cap: RUN_TABLE_CAP,
  }
}

///|
/// Keeps the table bounded. LIVE runs are never evicted — forgetting a running
/// task to satisfy a budget trades a visible memory bound for an invisible wrong
/// answer — so the ceiling may be exceeded while everything in the table is
/// live; that is the honest trade. Settled entries go oldest first, and the
/// eviction is REPORTED: a released resource nobody mentions is how a leak hides
/// (iron rule 1, AGENT.md).
fn RunTable::evict_over_cap(self : RunTable) -> Unit {
  if self.entries.length() <= self.cap {
    return
  }
  let settled : Array[Int32] = []
  for i = 0; i < self.entries.length(); i = i + 1 {
    if !(self.entries[i].state is Running) {
      settled.push(i)
    }
  }
  let want = self.entries.length() - self.cap
  let drop_count = if settled.length() < want { settled.length() } else { want }
  if drop_count == 0 {
    return
  }
  let kept : Array[RunEntry] = []
  for i = 0; i < self.entries.length(); i = i + 1 {
    let mut drop = false
    for k = 0; k < drop_count; k = k + 1 {
      if settled[k] == i {
        drop = true
      }
    }
    if !drop {
      kept.push(self.entries[i])
    }
  }
  self.entries.clear()
  for entry in kept {
    self.entries.push(entry)
  }
  self.evicted = self.evicted + drop_count.to_int64()
  note(
    "run table: evicted \{drop_count} settled run entries (cap \{self.cap}; \{self.evicted} evicted so far)",
  )
}

///|
/// A task that cannot stay up: how long a run may live and still count as a
/// failed attempt, how many such attempts make it a LOOP, and over what window.
/// Constants rather than flags: three numbers an operator would tune are three
/// numbers a gate would have to pin twice.
const CRASH_LOOP_MAX_LIFESPAN_MS : Int64 = 10000L

///|
const CRASH_LOOP_MIN_RUNS : Int64 = 3L

///|
const CRASH_LOOP_WINDOW_MS : Int64 = 60000L

///|
/// Tasks whose runs keep ending in SILENCE, quickly, and recently: a restart
/// storm. The runner already logs every restart, but "line by line in a log" is
/// not a thing an operator sees — a task that is up-but-not-staying-up must be a
/// fact in the table, the way `pending` is (P0-3, decision 113).
///
/// The judgment is deliberately about what the CONTROL PLANE can see by itself:
/// a run that ended `Offline` (silent — killed or crashed, not a graceful stop),
/// lived less than `max_lifespan_ms`, and did so within `window_ms`. Nothing here
/// guesses at exit codes the control plane never receives.
fn RunTable::crash_loops(
  self : RunTable,
  now : Int64,
  window_ms : Int64,
  max_lifespan_ms : Int64,
  min_runs : Int64,
) -> Array[(String, Int64)] {
  let names : Array[String] = []
  let counts : Array[Int64] = []
  for entry in self.entries {
    if entry.state is Offline {
      let lifespan = entry.last_seen_ms - entry.first_seen_ms
      if lifespan <= max_lifespan_ms && now - entry.last_seen_ms <= window_ms {
        let mut at = -1
        for i = 0; i < names.length(); i = i + 1 {
          if names[i] == entry.record.task {
            at = i
          }
        }
        if at >= 0 {
          counts[at] = counts[at] + 1L
        } else {
          names.push(entry.record.task)
          counts.push(1L)
        }
      }
    }
  }
  let out : Array[(String, Int64)] = []
  for i = 0; i < names.length(); i = i + 1 {
    if counts[i] >= min_runs {
      out.push((names[i], counts[i]))
    }
  }
  out
}

///|
/// Reports a run: the first report registers, every later one is a heartbeat,
/// and a report with `stopped` is the runner's last word. Returns true when
/// this is a run the table had not seen (a registration, for the log line).
fn RunTable::observe(
  self : RunTable,
  record : @client.RunRecord,
  now : Int64,
) -> Bool {
  for i = 0; i < self.entries.length(); i = i + 1 {
    if self.entries[i].record.id == record.id {
      self.entries[i] = RunEntry::{
        record,
        first_seen_ms: self.entries[i].first_seen_ms,
        last_seen_ms: now,
        state: if record.stopped {
          Stopped
        } else {
          Running
        },
      }
      return false
    }
  }
  self.entries.push(RunEntry::{
    record,
    first_seen_ms: now,
    last_seen_ms: now,
    state: if record.stopped {
      Stopped
    } else {
      Running
    },
  })
  self.evict_over_cap()
  true
}

///|
/// Ages out runs that went silent: `Running` entries whose last report is older
/// than the window become `Offline`. A `Stopped` entry is never reaped — that
/// is the whole point of recording how it ended.
fn RunTable::sweep(self : RunTable, now : Int64) -> Array[String] {
  let went_offline : Array[String] = []
  for i = 0; i < self.entries.length(); i = i + 1 {
    if self.entries[i].state is Running {
      if now - self.entries[i].last_seen_ms > self.timeout_ms {
        self.entries[i].state = Offline
        self.reaped = self.reaped + 1L
        went_offline.push(self.entries[i].record.id)
      }
    }
  }
  went_offline
}

///|
/// How many runs are in each state right now (for the label-free gauges: task
/// names are user input and a metric label must not be, so the TABLE is a
/// count and per-run detail goes through `CMD_RUN_LIST`).
fn RunTable::count(self : RunTable, state : RunState) -> Int32 {
  let mut total = 0
  for entry in self.entries {
    if entry.state == state {
      total = total + 1
    }
  }
  total
}

///|
/// The names of the tasks that have a RUNNING run right now, in first-seen
/// order and deduplicated (two runs of one task — a restart racing its
/// predecessor's reap — must not make the scheduler count two tasks). This is
/// the ACTUAL half of the scheduling table: desired comes from the task set,
/// and "running" comes from here, so the table can say `assigned` when a
/// worker owns a task nothing has reported yet.
fn RunTable::running_tasks(self : RunTable) -> Array[String] {
  let out : Array[String] = []
  for entry in self.entries {
    if entry.state is Running {
      let mut seen = false
      for name in out {
        if name == entry.record.task {
          seen = true
          break
        }
      }
      if !seen {
        out.push(entry.record.task)
      }
    }
  }
  out
}

///|
/// The rows, in id order — a listing that reorders itself between calls is a
/// listing nobody can diff. The `state` field is filled from the TABLE's view
/// (including the derived `offline`), because a runner does not get to declare
/// itself offline.
fn RunTable::rows(self : RunTable) -> Array[@client.RunRecord] {
  let out : Array[@client.RunRecord] = []
  for entry in self.entries {
    out.push(@client.RunRecord::{
      id: entry.record.id,
      task: entry.record.task,
      revision: entry.record.revision,
      address: entry.record.address,
      pid: entry.record.pid,
      data_dir: entry.record.data_dir,
      progress: entry.record.progress,
      stopped: entry.record.stopped,
      state: run_state_text(entry.state),
    })
  }
  sort_runs(out)
  out
}

///|
/// Insertion sort by id: run tables are small (one row per running process).
fn sort_runs(records : Array[@client.RunRecord]) -> Unit {
  for i = 1; i < records.length(); i = i + 1 {
    let mut j = i
    while j > 0 && records[j - 1].id > records[j].id {
      let tmp = records[j - 1]
      records[j - 1] = records[j]
      records[j] = tmp
      j = j - 1
    }
  }
}

///|
/// The wire name of a state, for listings and gates.
fn run_state_text(state : RunState) -> String {
  match state {
    Running => "running"
    Stopped => "stopped"
    Offline => "offline"
  }
}

///|
/// One tab-separated line per run (the shape `topic list` uses, so `cut -f1`
/// and `grep '^id'` work in a gate).
fn run_list_lines(records : Array[@client.RunRecord]) -> Array[String] {
  let out : Array[String] = []
  for record in records {
    let progress = if record.progress < 0L {
      "-"
    } else {
      record.progress.to_string()
    }
    out.push(
      "\{record.id}\ttask=\{record.task}\tstate=\{record.state}\trevision=\{record.revision}\tpid=\{record.pid}\tprogress=\{progress}",
    )
  }
  out
}
