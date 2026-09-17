// SPDX-License-Identifier: Apache-2.0
// Topic log storage helpers: one directory per topic, one segment
// file per partition (P0: partition 0 only).

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
/// Opens (or recovers) one partition's log. Recovery semantics are
/// identical across partitions: a torn or corrupt tail truncates to the
/// confirmed prefix, never silently.
fn open_partition_log(
  data_dir : String,
  topic : String,
  partition : Int,
) -> Result[@log.SegmentedLog, String] {
  if not(valid_topic(topic)) {
    return Err("invalid topic name '\{topic}'")
  }
  let dir = "\{data_dir}/topics/\{topic}"
  match @fs.mkdirs(dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{dir}: \{e}")
  }
  let handle = match
    @fs.open_segment_file(topic_log_path(data_dir, topic, partition)) {
    Ok(handle) => handle
    Err(e) => return Err("open segment: \{e}")
  }
  match @log.SegmentedLog::open(handle) {
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
