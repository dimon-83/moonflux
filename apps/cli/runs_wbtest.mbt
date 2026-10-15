// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the run table's memory bound (iron rule 1, AGENT.md).
//
// Why this is a unit test rather than a gate leg: the property is "the table
// cannot grow without bound", and a gate would have to run a control plane for
// long enough to accumulate >cap runs to show it. The table is small and its
// rule is local, so the honest place to pin it is here — and a leak that needs a
// long-running process to appear is exactly the kind that a short gate misses.

///|
fn run_record(id : String, stopped : Bool) -> @client.RunRecord {
  @client.RunRecord::{
    id,
    task: "t",
    revision: 0L,
    address: "127.0.0.1:1",
    pid: 1,
    data_dir: "/tmp",
    progress: -1L,
    stopped,
    // a REPORTER leaves this empty: the platform fills "running"/"stopped"/"offline"
    state: "",
  }
}

///|
fn run_record_of(
  id : String,
  task : String,
  stopped : Bool,
) -> @client.RunRecord {
  @client.RunRecord::{
    id,
    task,
    revision: 0L,
    address: "127.0.0.1:1",
    pid: 1,
    data_dir: "/tmp",
    progress: -1L,
    stopped,
    state: "",
  }
}

///|
/// A task that cannot stay up. Three attempts, each alive for ~100ms and then
/// SILENT (killed or crashed, not a graceful stop), all inside the window.
test "crash_loops: repeated short silent deaths are named" {
  let table = RunTable::new(3000L)
  for i = 0; i < 3; i = i + 1 {
    let _ = table.observe(
      run_record_of("flappy-\{i}", "flappy", false),
      1000L + i.to_int64() * 100L,
    )
  }
  // the sweep needs now - last_seen > the 3000ms liveness window, or nothing has
  // gone silent yet and there is no storm to see
  let _ = table.sweep(5000L)
  let loops = table.crash_loops(5000L, 60_000L, 10_000L, 3L)
  assert_eq(loops.length(), 1)
  let (name, count) = loops[0]
  assert_eq(name, "flappy")
  assert_eq(count, 3L)
}

///|
/// The counter-example that keeps the mark honest: runs that lived a long time
/// (or ended gracefully) are not a restart storm. A mark that fires on those
/// would be noise, and noise is how a real one gets ignored.
test "crash_loops: long runs and graceful stops are not a storm" {
  let table = RunTable::new(3000L)
  // three runs of the same task, each reporting for well past the lifespan bar
  for i = 0; i < 3; i = i + 1 {
    let t0 = 1000L + i.to_int64() * 20_000L
    let _ = table.observe(run_record_of("long-\{i}", "long", false), t0)
    let _ = table.observe(
      run_record_of("long-\{i}", "long", false),
      t0 + 15_000L,
    )
  }
  // and one that stopped on purpose
  let _ = table.observe(run_record_of("clean", "clean", true), 1000L)
  let _ = table.sweep(80_000L)
  assert_eq(table.crash_loops(80_000L, 60_000L, 10_000L, 3L).length(), 0)
}

///|
test "the run table evicts settled entries and says how many" {
  let table = RunTable::new(3000L)
  let cap = table.cap
  // cap + 5 entries, every other one settled, so there is something evictable
  for i = 0; i < cap + 5; i = i + 1 {
    let _ = table.observe(run_record("run-\{i}", i % 2 == 0), 1000L)
  }
  assert_eq(table.entries.length(), cap)
  assert_eq(table.evicted, 5L)
}

///|
test "a live run is never evicted to satisfy the budget" {
  let table = RunTable::new(3000L)
  let cap = table.cap
  // everything is live: the ceiling may be exceeded, because forgetting a
  // running task to satisfy a budget trades a visible bound for an invisible
  // wrong answer
  for i = 0; i < cap + 3; i = i + 1 {
    let _ = table.observe(run_record("live-\{i}", false), 1000L)
  }
  assert_eq(table.entries.length(), cap + 3)
  assert_eq(table.evicted, 0L)
}
