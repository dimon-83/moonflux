// SPDX-License-Identifier: Apache-2.0
// Topic log storage helpers: one directory per topic, one segment
// file per partition (P0: partition 0 only).

///|
/// True when this partition has stored bytes — the pre-P8 single file
/// or at least one segment. Read-only on purpose: a heartbeat must not
/// create a log for a topic this node was never given.
fn partition_has_bytes(
  data_dir : String,
  topic : String,
  partition : Int,
) -> Bool {
  match @fs.exists(topic_log_path(data_dir, topic, partition)) {
    Ok(true) => return true
    _ => ()
  }
  let dir = "\{data_dir}/topics/\{topic}/partition-\{partition}"
  match @fs.list_dir(dir) {
    Ok(names) => names.length() > 0
    Err(_) => false
  }
}

///|
/// A partition's segment file. The layout is one file per partition
/// under the topic's directory; partition 0 predates multi-partition
/// storage, which is why every pre-P5 caller passes 0.
fn topic_log_path(data_dir : String, topic : String, partition : Int) -> String {
  "\{data_dir}/topics/\{topic}/partition-\{partition}.log"
}

///|
fn open_topic_log(
  data_dir : String,
  topic : String,
) -> Result[@log.SegmentedLog, String] {
  open_partition_log(data_dir, topic, 0)
}

///|
/// How many bytes a segment may hold before the log rolls to a new one
/// (P8). Configurable because the value is a policy, not a fact: the
/// storage gate sets it small to exercise rolling with a few records.
fn roll_bytes() -> Int {
  match @env.get_env_var("MOONFLUX_ROLL_BYTES") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n > 0 => n
        _ => DEFAULT_ROLL_BYTES
      }
    None => DEFAULT_ROLL_BYTES
  }
}

///|
const DEFAULT_ROLL_BYTES : Int = 1048576

///|
/// Opens (or recovers) one partition's log. Recovery semantics are
/// identical across partitions: a torn or corrupt tail truncates to the
/// confirmed prefix, never silently.
///
/// Layout (P8): `topics/<topic>/partition-<N>/<base>.log`, one file per
/// segment, named by the offset of its first record. A pre-P8 install
/// has a single `partition-<N>.log`; it is migrated once by rename
/// (atomic) and becomes segment 0 — the same log, now with boundaries.
fn open_partition_log(
  data_dir : String,
  topic : String,
  partition : Int,
) -> Result[@log.SegmentedLog, String] {
  if not(valid_topic(topic)) {
    return Err("invalid topic name '\{topic}'")
  }
  let topic_dir = "\{data_dir}/topics/\{topic}"
  match @fs.mkdirs(topic_dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{topic_dir}: \{e}")
  }
  let dir = "\{topic_dir}/partition-\{partition}"
  match @fs.mkdirs(dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{dir}: \{e}")
  }
  let legacy = topic_log_path(data_dir, topic, partition)
  match @fs.exists(legacy) {
    Ok(true) => {
      let target = "\{dir}/\{@fs.segment_file_name(0L)}"
      match @fs.rename(legacy, target) {
        Ok(_) =>
          note(
            "migrated \{legacy} to the segmented layout (\{target}); offsets are unchanged",
          )
        Err(e) => return Err("migrate \{legacy} -> \{target}: \{e}")
      }
    }
    _ => ()
  }
  let store = match @fs.open_segment_store(dir) {
    Ok(store) => store
    Err(e) => return Err("open segment store \{dir}: \{e}")
  }
  match @log.SegmentedLog::open_store(store, roll_bytes()) {
    Ok(log) => {
      // never silent: recovery that discarded bytes is surfaced
      if !(log.recovery.reason is Clean) {
        println(
          "warning: topic \{topic} recovery discarded \{log.recovery.discarded_bytes} bytes (\{log.recovery.reason}); watermark restored to \{log.high_watermark()}",
        )
      }
      Ok(log)
    }
    Err(e) => Err("recover log: \{e}")
  }
}
