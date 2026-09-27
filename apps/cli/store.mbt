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
/// The retention policy in force (P8/T46). Both bounds default to 0 =
/// off, because deletion is never a default: an operator asks for it.
fn retention_policy() -> @log.RetentionPolicy {
  let max_bytes = match @env.get_env_var("MOONFLUX_RETAIN_BYTES") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n > 0 => n
        _ => 0
      }
    None => 0
  }
  let max_age_ms = match @env.get_env_var("MOONFLUX_RETAIN_MS") {
    Some(text) =>
      match (try? @string.parse_int64(text[0:text.length()])) {
        Ok(n) if n > 0L => n
        _ => 0L
      }
    None => 0L
  }
  @log.RetentionPolicy::{ max_bytes, max_age_ms, }
}

///|
/// Age-based rolling (P8/T46): 0 = size-based rolling only.
fn roll_after_ms() -> Int64 {
  match @env.get_env_var("MOONFLUX_ROLL_MS") {
    Some(text) =>
      match (try? @string.parse_int64(text[0:text.length()])) {
        Ok(n) if n > 0L => n
        _ => 0L
      }
    None => 0L
  }
}

///|
/// One retention pass over a partition's log: roll if the active
/// segment has aged out, then drop whole segments that are both below
/// `floor` and outside the policy. Returns the number of segments
/// dropped, so a caller can log it — deletion is never silent.
///
/// `floor` is the caller's judgement, and the caller in this codebase
/// passes the committed prefix: data no replica needs any more. A
/// consumer reading below the resulting start gets a structured
/// `OffsetOutOfRange`, not an empty window (README 决策 31).
fn retain_partition(
  data_dir : String,
  topic : String,
  partition : Int,
  floor : Int64,
  now_ms : Int64,
) -> Result[Int, String] {
  let log = match open_partition_log(data_dir, topic, partition) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  match log.roll_due(now_ms, roll_after_ms()) {
    Ok(true) =>
      note(
        "rolled \{topic}[\{partition}] at offset \{log.high_watermark()} (segment age policy)",
      )
    Ok(false) => ()
    Err(e) => note("warning: cannot roll \{topic}[\{partition}]: \{e}")
  }
  let policy = retention_policy()
  let report = match log.apply_retention(floor, now_ms, policy) {
    Ok(report) => report
    Err(e) => return Err("retention \{topic}[\{partition}]: \{e}")
  }
  for summary in report.removed {
    note(
      "retained away \{topic}[\{partition}] segment at \{summary.base} (\{summary.records} records, \{summary.bytes} bytes); earliest readable offset is now \{log.first_offset()}",
    )
  }
  Ok(report.removed.length())
}

///|
/// One compaction pass over a partition's log (P14): records below
/// `floor` whose key occurs again below `floor` are dropped, survivors
/// keep their offsets. `floor` is the caller's judgement in the same
/// sense retention uses it — the committed prefix, lowered by whatever
/// consumers still need — because the decision has to be a function of
/// data every replica holds, or two replicas would compact differently.
///
/// Deletion is never silent: every rewritten segment is reported, and
/// the total follows.
fn compact_partition(
  data_dir : String,
  topic : String,
  partition : Int,
  floor : Int64,
  now_ms : Int64,
) -> Result[@log.CompactionReport, String] {
  let log = match open_partition_log(data_dir, topic, partition) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  let report = match
    log.apply_compaction(floor, now_ms, @log.CompactionPolicy::{
      min_dirty_bytes: 0,
    }) {
    Ok(report) => report
    Err(e) => return Err("compaction \{topic}[\{partition}]: \{e}")
  }
  for seg in report.rewritten {
    note(
      "compacted \{topic}[\{partition}] segment at \{seg.base}: \{seg.frames_before} -> \{seg.frames_after} frames, \{seg.dropped_records} records dropped, \{seg.bytes_before} -> \{seg.bytes_after} bytes",
    )
  }
  if report.rewritten.length() > 0 {
    note(
      "compaction \{topic}[\{partition}] (floor \{floor}): \{report.rewritten.length()} segment(s) rewritten, \{report.dropped_records()} records dropped, \{report.freed_bytes()} bytes freed",
    )
  }
  Ok(report)
}

///|
/// How many records may pass between index anchors (P8/T45). Same
/// reasoning as the roll threshold: policy, so it is configurable, and
/// the storage gate sets it small to exercise the index.
fn index_every_records() -> Int {
  match @env.get_env_var("MOONFLUX_INDEX_EVERY") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n > 0 => n
        _ => 64
      }
    None => 64
  }
}

///|
/// Opens (or recovers) one partition's log — **once per process** (P16).
///
/// Callers keep asking by name, which is what makes the cache cheap to
/// use and safe to evict: nothing holds a handle across calls, so the
/// cache can always be the only owner (see `logcache.mbt` for why that
/// invariant is the whole design). The recovery scan below is the
/// expensive part, and paying it per *request* is what made a node miss
/// its heartbeat window under load.
fn open_partition_log(
  data_dir : String,
  topic : String,
  partition : Int,
) -> Result[@log.SegmentedLog, String] {
  match log_cache.get(data_dir, topic, partition) {
    Some(log) => return Ok(log)
    None => ()
  }
  let log = match open_partition_log_uncached(data_dir, topic, partition) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  log_cache.put(data_dir, topic, partition, log)
  // One line per open, and an open is now a rare event: this is the
  // counter that says whether the cache is doing its job (a regression
  // to per-request opens shows up here as a line per request).
  //
  // On *stderr*, like every other diagnostic: a CLI data command's
  // stdout is its record stream, and a log line mixed into it is
  // indistinguishable from a record (`consume | cut -f4` is a thing
  // people do).
  warn(
    "opened \{topic}[\{partition}] (log end \{log.high_watermark()}, \{log.segment_summaries().length()} segment(s))\n",
  )
  Ok(log)
}

///|
/// The actual open: migrate a pre-P8 single file, recover the tail,
/// rebuild the active segment's anchors. Recovery semantics are
/// identical across partitions: a torn or corrupt tail truncates to the
/// confirmed prefix, never silently.
///
/// Layout (P8): `topics/<topic>/partition-<N>/<base>.log`, one file per
/// segment, named by the offset of its first record. A pre-P8 install
/// has a single `partition-<N>.log`; it is migrated once by rename
/// (atomic) and becomes segment 0 — the same log, now with boundaries.
fn open_partition_log_uncached(
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
  match
    @log.SegmentedLog::open_store_configured(
      store,
      roll_bytes(),
      index_every_records(),
    ) {
    Ok(log) => {
      // never silent: recovery that discarded bytes is surfaced — and
      // through `note`, which flushes, because a warning a running
      // process never writes to its log is a warning nobody sees
      if !(log.recovery.reason is Clean) {
        note(
          "warning: topic \{topic}[\{partition}] recovery discarded \{log.recovery.discarded_bytes} bytes (\{log.recovery.reason}); watermark restored to \{log.high_watermark()}",
        )
      }
      Ok(log)
    }
    Err(e) => Err("recover log: \{e}")
  }
}
