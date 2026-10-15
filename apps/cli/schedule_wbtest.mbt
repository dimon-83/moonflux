// SPDX-License-Identifier: Apache-2.0
// White-box tests for the scheduling reconciliation (P37-5b): placement is a
// PURE function of (live worker set, task list, running set) — which is what
// makes it testable without a control plane, and what keeps a task from
// flapping between two workers on consecutive ticks.

///|
/// Builds a task-set document for the tests: each entry is
/// (name, target, enabled); an empty target means "any" (absent in the JSON).
/// One topic per task (`in-<name>`), because two tasks on one topic cannot
/// coexist in a set (validate_tasks refuses them).
fn sched_doc(specs : Array[(String, String, Bool)]) -> String {
  let parts : Array[String] = []
  for spec in specs {
    let (name, target, enabled) = spec
    let t = if target == "" { "" } else { ",\"target\":\"\{target}\"" }
    let e = if enabled { "true" } else { "false" }
    parts.push(
      "{\"pipeline\":\"\{name}\"\{t},\"enabled\":\{e},\"spec\":{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"\{name}\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"in-\{name}\",\"from\":\"beginning\"},\"topic\":{\"name\":\"in-\{name}\"},\"transforms\":[],\"sink\":{\"type\":\"stdout\"}}}}",
    )
  }
  "{\"pipelines\":[" + parts.join(",") + "]}"
}

///|
/// Ticks a scheduler against a document with the workers currently in the
/// registry (observe them first) and the given running set.
fn sched_tick(
  scheduler : Scheduler,
  doc : String,
  workers : WorkerRegistry,
  running : Array[String],
) -> Unit {
  scheduler.tick(doc, 7L, workers, running, [])
}

///|
/// The same tick, with the crash-loop half of the actual state supplied.
fn sched_tick_loops(
  scheduler : Scheduler,
  doc : String,
  workers : WorkerRegistry,
  running : Array[String],
  crash_loops : Array[(String, Int64)],
) -> Unit {
  scheduler.tick(doc, 7L, workers, running, crash_loops)
}

///|
fn sched_row(
  rows : Array[@client.ScheduleRow],
  name : String,
) -> @client.ScheduleRow {
  for row in rows {
    if row.task == name {
      return row
    }
  }
  abort("no row for \{name}")
}

///|
/// A pinned task runs on the worker it named, when that worker is live. A
/// placement the scheduler cannot explain is a placement nobody can trust.
test "pinned task goes to its live target" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  sched_tick(scheduler, sched_doc([("relay-a", "worker-a", true)]), workers, [])
  let row = sched_row(scheduler.rows, "relay-a")
  assert_eq(row.owner, "worker-a")
  // nothing is reporting yet: the gap is the point of the table, and the row
  // says "assigned", not "running"
  assert_eq(row.state, "assigned")
  assert_eq(row.reason, "")
}

///|
/// A pin is a DECLARATION, not a preference: the control plane does not move
/// a pinned task to a different worker when its target is gone — silently
/// running it somewhere else would look identical to a correct placement.
/// The row stays and says why, forever.
test "pinned task whose target is gone is pending, not reassigned" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  let _ = workers.observe("worker-b", 0L)
  sched_tick(scheduler, sched_doc([("relay-a", "worker-c", true)]), workers, [])
  let row = sched_row(scheduler.rows, "relay-a")
  assert_eq(row.owner, "")
  assert_eq(row.state, "pending")
  assert_true(row.reason.contains("worker-c"))
  // and nobody else picked it up
  assert_eq(scheduler.placement_for("worker-a").tasks.length(), 0)
  assert_eq(scheduler.placement_for("worker-b").tasks.length(), 0)
}

///|
/// Floating work goes to the least-loaded live worker, ties by lowest id.
/// Two floats split across two idle workers deterministically: the first
/// (lowest id) takes the first task, the second takes the next — the answer
/// is a function of the inputs, not of iteration order.
test "floating tasks spread by load, ties by lowest id" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-b", 0L)
  let _ = workers.observe("worker-a", 0L)
  sched_tick(
    scheduler,
    sched_doc([("f-1", "", true), ("f-2", "", true)]),
    workers,
    [],
  )
  assert_eq(sched_row(scheduler.rows, "f-1").owner, "worker-a")
  assert_eq(sched_row(scheduler.rows, "f-2").owner, "worker-b")
}

///|
/// A disabled task is a row WITH A REASON, not an invisible one — and it is
/// excluded from every placement, so a worker that held it before the flip
/// stops being told to run it.
test "disabled task says why and is placed nowhere" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  sched_tick(scheduler, sched_doc([("relay-a", "worker-a", false)]), workers, [])
  let row = sched_row(scheduler.rows, "relay-a")
  assert_eq(row.state, "disabled")
  assert_eq(row.owner, "")
  assert_true(row.reason.contains("enabled=false"))
  assert_eq(scheduler.placement_for("worker-a").tasks.length(), 0)
}

///|
/// The ACTUAL half: a run that reports turns the row from `assigned` (the
/// worker owns it, nothing reported yet) to `running` — the gap the table
/// exists to show.
test "a reporting run turns assigned into running" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  let doc = sched_doc([("relay-a", "worker-a", true)])
  sched_tick(scheduler, doc, workers, [])
  assert_eq(sched_row(scheduler.rows, "relay-a").state, "assigned")
  sched_tick(scheduler, doc, workers, ["relay-a"])
  assert_eq(sched_row(scheduler.rows, "relay-a").state, "running")
}

///|
/// Reassignment, the whole event: the owner goes silent, the sweep drops it,
/// and the FLOATING task moves to a survivor — while a PINNED task whose
/// target died stays pending (previous test). The scheduler remembers who
/// held the task so the move is noticed once, as a sentence.
test "losing the owner reassigns floating work to the survivor" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  let _ = workers.observe("worker-b", 0L)
  let doc = sched_doc([("f-1", "", true)])
  sched_tick(scheduler, doc, workers, ["f-1"])
  assert_eq(sched_row(scheduler.rows, "f-1").owner, "worker-a")
  // worker-a goes silent past the window; worker-b keeps beating, so the
  // sweep drops exactly one of them
  let _ = workers.observe("worker-b", 3000L)
  let gone = workers.sweep(4000L)
  assert_eq(gone, ["worker-a"])
  sched_tick(scheduler, doc, workers, ["f-1"])
  assert_eq(sched_row(scheduler.rows, "f-1").owner, "worker-b")
  assert_eq(sched_row(scheduler.rows, "f-1").state, "running")
}

///|
/// A control plane with no task set has NO OPINION — `has_set` is what lets
/// a worker tell "run nothing" from "I was never asked", which is why a
/// locally applied set survives being pointed at a fresh control plane.
test "no document means no opinion, not an empty placement" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  sched_tick(scheduler, "", workers, [])
  assert_eq(scheduler.rows.length(), 0)
  let placement = scheduler.placement_for("worker-a")
  assert_eq(placement.has_set, false)
  // the revision rides along: this is the number the runner keys adoption on
  assert_eq(placement.revision, 7L)
  assert_eq(placement.tasks.length(), 0)
}

///|
/// "UP SOMETIMES, dying constantly" must not hide behind `running`. A task in a
/// restart storm reports occasionally, and reporting occasionally is exactly the
/// state that would otherwise look healthy (P0-3). The mark OVERRIDES running
/// and carries the count, because "it is crash-looping" without "how often" is a
/// sentence an operator cannot act on.
test "a crash-looping task overrides running and says how often" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  let doc = sched_doc([("relay-a", "worker-a", true)])
  sched_tick_loops(scheduler, doc, workers, ["relay-a"], [("relay-a", 5L)])
  let row = sched_row(scheduler.rows, "relay-a")
  assert_eq(row.state, "crash-loop")
  assert_true(row.reason.contains("5 run(s)"))
  assert_true(row.reason.contains("cannot stay up"))
  // and a healthy sibling is untouched: the mark is per task, not per cluster
  sched_tick_loops(
    scheduler,
    sched_doc([("relay-a", "worker-a", true), ("relay-b", "worker-a", true)]),
    workers,
    ["relay-a", "relay-b"],
    [("relay-a", 5L)],
  )
  assert_eq(sched_row(scheduler.rows, "relay-b").state, "running")
}

///|
/// An operator who STOPPED the task has already said what they want: a stopped
/// task is `disabled`, not `crash-loop`. Precedence is part of the contract, so
/// it is pinned rather than assumed.
test "disabled wins over a crash loop" {
  let scheduler = Scheduler::new()
  let workers = WorkerRegistry::new(3000L)
  let _ = workers.observe("worker-a", 0L)
  sched_tick_loops(
    scheduler,
    sched_doc([("relay-a", "worker-a", false)]),
    workers,
    [],
    [("relay-a", 9L)],
  )
  let row = sched_row(scheduler.rows, "relay-a")
  assert_eq(row.state, "disabled")
  assert_true(row.reason.contains("enabled=false"))
}
