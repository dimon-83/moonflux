///|
/// The run record's boundary: a run whose source has no offsets sends -1, and
/// the varints here are unsigned while the writer emits signed LEB128 — so -1
/// used to arrive as 127 (measured in the P37-2 listing: a file source "had
/// consumed offset 127"). Pin every shape of the field.
test "run record progress round-trips, including 'no offsets'" {
  for progress in [-1L, 0L, 1L, 127L, 1000000L, 1099511627776L] {
    let record = RunRecord::{
      id: "task@3#0",
      task: "task",
      revision: 3L,
      address: "host",
      pid: 4242,
      data_dir: "/tmp/d",
      progress,
      stopped: false,
      state: "",
    }
    match decode_run(encode_run(record)) {
      Ok(back) => {
        assert_eq(back.progress, progress)
        assert_eq(back.id, record.id)
        assert_eq(back.pid, 4242)
      }
      Err(e) => abort("decode failed: \{e}")
    }
  }
}

///|
/// The worker beat round-trips. The worker id's bounds are enforced on DECODE
/// (an empty or oversized id would make the scheduling table lie about who
/// asked), so both directions get a leg.
test "worker beat and placement round-trip" {
  let beat = WorkerBeat::{
    worker: "worker-a",
    address: "host-1",
    data_dir: "/tmp/d",
  }
  match decode_worker_beat(encode_worker_beat(beat)) {
    Ok(back) => {
      assert_eq(back.worker, "worker-a")
      assert_eq(back.address, "host-1")
      assert_eq(back.data_dir, "/tmp/d")
    }
    Err(e) => abort("decode worker beat failed: \{e}")
  }
  for
    bad in [
      "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    ] {
    let payload = encode_worker_beat(WorkerBeat::{
      worker: bad,
      address: "h",
      data_dir: "d",
    })
    assert_true(decode_worker_beat(payload) is Err(_))
  }
  let placement = WorkerPlacement::{
    has_set: true,
    revision: 42L,
    tasks: ["relay-a", "relay-b"],
  }
  match decode_worker_placement(encode_worker_placement(placement)) {
    Ok(back) => {
      assert_eq(back.has_set, true)
      assert_eq(back.revision, 42L)
      assert_eq(back.tasks, ["relay-a", "relay-b"])
    }
    Err(e) => abort("decode placement failed: \{e}")
  }
  let none = WorkerPlacement::{ has_set: false, revision: 0L, tasks: [], }
  match decode_worker_placement(encode_worker_placement(none)) {
    Ok(back) => {
      assert_eq(back.has_set, false)
      assert_eq(back.tasks.length(), 0)
    }
    Err(e) => abort("decode empty placement failed: \{e}")
  }
}

///|
/// The scheduling table's rows round-trip, including a pending row whose
/// reason is the whole point of the table.
test "schedule rows round-trip" {
  let rows = [
    ScheduleRow::{
      task: "relay-a",
      target: "worker-a",
      owner: "worker-a",
      state: "running",
      reason: "",
    },
    ScheduleRow::{
      task: "relay-c",
      target: "worker-c",
      owner: "",
      state: "pending",
      reason: "target worker worker-c has no live runner (a pin is a declaration: not reassigned)",
    },
  ]
  match decode_schedule_rows(encode_schedule_rows(rows)) {
    Ok(back) => {
      assert_eq(back.length(), 2)
      assert_eq(back[0].state, "running")
      assert_eq(back[1].state, "pending")
      assert_eq(back[1].reason, rows[1].reason)
    }
    Err(e) => abort("decode schedule rows failed: \{e}")
  }
}

///|
/// The task-enabled flip: one field, one byte, and the byte is checked —
/// a truncated or garbage flag is a refusal, not a guess.
test "task enabled round-trip and byte bounds" {
  match decode_task_enabled(encode_task_enabled("relay-a", true)) {
    Ok((name, enabled)) => {
      assert_eq(name, "relay-a")
      assert_eq(enabled, true)
    }
    Err(e) => abort("decode task enabled failed: \{e}")
  }
  match decode_task_enabled(encode_task_enabled("relay-a", false)) {
    Ok((name, enabled)) => {
      assert_eq(name, "relay-a")
      assert_eq(enabled, false)
    }
    Err(e) => abort("decode task enabled(false) failed: \{e}")
  }
  assert_true(decode_task_enabled(encode_task_enabled("", true)) is Err(_))
  let truncated = @buffer.Buffer::Buffer()
  truncated.write_byte(b'\x02')
  assert_true(decode_task_enabled(truncated.to_bytes()) is Err(_))
}
