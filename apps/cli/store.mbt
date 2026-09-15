// SPDX-License-Identifier: Apache-2.0
// Topic log storage helpers: one directory per topic, one segment
// file per partition (P0: partition 0 only).

///|
fn topic_log_path(data_dir : String, topic : String) -> String {
  "\{data_dir}/topics/\{topic}/partition-0.log"
}

///|
fn open_topic_log(
  data_dir : String,
  topic : String,
) -> Result[@log.SegmentedLog, String] {
  if not(valid_topic(topic)) {
    return Err("invalid topic name '\{topic}'")
  }
  let dir = "\{data_dir}/topics/\{topic}"
  match @fs.mkdirs(dir) {
    Ok(_) => ()
    Err(e) => return Err("mkdir \{dir}: \{e}")
  }
  let handle = match @fs.open_segment_file(topic_log_path(data_dir, topic)) {
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
