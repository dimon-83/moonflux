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
