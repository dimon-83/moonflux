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
