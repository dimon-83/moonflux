// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the STUCK-VALUE (卡值/恒值) operator.
//
// WHY THIS OPERATOR EXISTS
//
// A point that stops moving is a failed instrument, and the naive rule — "the
// value has been identical for the last N minutes" — is nearly useless on a real
// plant tag. Measured on one real feed (ia_csc.inlet_node_value, CN_进水COD,
// 5732 samples over 4 days):
//
//   * 92.2% of adjacent samples are IDENTICAL: a flat value is the normal state,
//     not the anomaly;
//   * "flat for at least 10 minutes" happens 12.8 times a day;
//   * changes are REAL STEPS (smallest |Δ| = 1.447, none below 1e-3), so no
//     deadband is wanted — bit-equality is the right test;
//   * sampling is not even (59s…300s gaps exist) and bad-quality samples appear,
//     so a window of N SAMPLES is not a window of N MINUTES.
//
// So the operator reports a DURATION and judges it against two lines: a notice
// line (the "is it flat in the window" question) and an alarm line (calibrated
// from that point's OWN history — see the `over_alarm`/`runs` counters it keeps).
// Everything is driven by the event time carried in the records: this guest has
// no clock (the kernel red line), and a duration computed from record timestamps
// is deterministic and replayable.
//
// Config (through mf_op_init; unknown keys are refused):
//
//   {"value_field":"var_value","ts_field":"ts","node_field":"node_name",
//    "quality_field":"var_quality","status_field":"data_status",
//    "notice_minutes":10,"alarm_minutes":150,"max_gap_ms":180000,
//    "deadband":0.0,"good_quality":[192],"good_status":["正常"],
//    "suspicious_values":[5000],"clear_minutes":5,"heartbeat_minutes":30,
//    "emit_all":false}
//
// Input: each record's value is either a JSON ARRAY of rows (what a polling HTTP
// source produces from a PostgREST reply) or a single row object:
//
//   [{"node_name":"CN_进水COD","var_value":1121.238403,
//     "ts":"2026-10-13T20:19:00.556+08:00","var_quality":192,"data_status":"正常"}]
//
// Output: one record per DECISION (not per input row), keyed by node name:
//
//   {"node":"CN_进水COD","verdict":"NOTICE","value":1121.238403,
//    "flat_minutes":96,"at":"2026-10-13T20:19:00.556Z","runs":12,"over_alarm":1,
//    "reason":"..."}
//
//   verdict ∈ OK | FLAT | NOTICE | STUCK | NO_DATA
//
// Decisions are emitted on the first sight of a node, on every verdict change,
// and as a heartbeat every `heartbeat_minutes` of EVENT time — silence must not
// be mistaken for health. `emit_all` emits one per row instead (debugging).
//
// State (ABI v3, one entry per node, value is ASCII `k=v;` pairs):
//
//   n=<completed runs>;over_n=<runs that passed the notice line>;
//   over_a=<runs that passed the alarm line>;v=<value>;start=<ms>;last=<ms>;
//   alert=<0|1>;alertv=<value>;changed=<ms>;emit=<ms>;verdict=<name>
//
// The state topic is the durable truth: a restart replays it, so a flat period
// that spans a restart is one run, not two.
//
// WHAT THIS OPERATOR DOES NOT DO
//
// It cannot see a feed that stopped entirely: "no records at all" is not an
// event, and this guest has no clock to notice it. That half belongs to the
// platform's run registration (a run that dies stops reporting) and to the
// pipeline's own liveness — the operator covers data gaps *between* records,
// which is a different and complementary question.

///|
/// The three lines and the field names, parsed once per batch call.
priv struct StuckConfig {
  mut value_field : String
  mut ts_field : String
  mut node_field : String
  mut quality_field : String
  mut status_field : String
  mut window_minutes : Double
  mut notice_minutes : Double
  mut alarm_minutes : Double
  mut max_gap_ms : Int64
  mut deadband : Double
  mut good_quality : Array[Double]
  mut good_status : Array[String]
  mut suspicious : Array[Double]
  mut clear_minutes : Double
  mut heartbeat_minutes : Double
  mut emit_all : Bool
}

///|
priv struct ConfigCell {
  mut cfg : StuckConfig?
}

///|
let config_cell : ConfigCell = ConfigCell::{ cfg: None, }

///|
fn active_config() -> Result[StuckConfig, String] {
  match config_cell.cfg {
    Some(cfg) => Ok(cfg)
    None => Err("mf_op_init was not called before mf_op_state_apply")
  }
}

///|
fn default_config() -> StuckConfig {
  StuckConfig::{
    value_field: "var_value",
    ts_field: "ts",
    node_field: "node_name",
    quality_field: "var_quality",
    status_field: "data_status",
    window_minutes: 10.0,
    // 10 minutes is the window the operator answers about; 150 minutes is the
    // alarm line measured on the real tag (a flat valley between two clusters
    // of run lengths — see the README decision record).
    notice_minutes: 10.0,
    alarm_minutes: 150.0,
    max_gap_ms: 180000L,
    deadband: 0.0,
    good_quality: [192.0],
    good_status: ["正常"],
    suspicious: [5000.0],
    clear_minutes: 5.0,
    heartbeat_minutes: 30.0,
    emit_all: false,
  }
}

///|
fn number_field(
  cfg : Map[String, Json],
  key : String,
  into : (Double) -> Unit,
) -> Bool {
  match cfg.get(key) {
    None => true
    Some(Number(n)) => {
      into(n)
      true
    }
    Some(_) => false
  }
}

///|
fn parse_config(config : Bytes) -> Result[StuckConfig, String] {
  let raw = match @sdk.parse_config(config) {
    Ok(raw) => raw
    Err(e) => return Err(e)
  }
  let out = default_config()
  for key in raw.keys() {
    match key {
      "value_field"
      | "ts_field"
      | "node_field"
      | "quality_field"
      | "status_field" =>
        match raw.get(key) {
          Some(String(text)) =>
            match key {
              "value_field" => out.value_field = text
              "ts_field" => out.ts_field = text
              "node_field" => out.node_field = text
              "quality_field" => out.quality_field = text
              _ => out.status_field = text
            }
          _ => return Err("\{key} must be a string")
        }
      "window_minutes"
      | "notice_minutes"
      | "alarm_minutes"
      | "deadband"
      | "clear_minutes"
      | "heartbeat_minutes" => {
        let mut seen = false
        let ok = number_field(raw, key, fn(n) {
          seen = true
          match key {
            "window_minutes" => out.window_minutes = n
            "notice_minutes" => out.notice_minutes = n
            "alarm_minutes" => out.alarm_minutes = n
            "deadband" => out.deadband = n
            "clear_minutes" => out.clear_minutes = n
            _ => out.heartbeat_minutes = n
          }
        })
        if !ok || !seen {
          return Err("\{key} must be a number")
        }
      }
      "max_gap_ms" =>
        match raw.get(key) {
          Some(Number(n)) => out.max_gap_ms = n.to_int64()
          _ => return Err("max_gap_ms must be a number")
        }
      "good_quality" | "suspicious_values" =>
        match raw.get(key) {
          Some(Array(items)) => {
            let numbers : Array[Double] = []
            for item in items {
              match item {
                Number(n) => numbers.push(n)
                _ => return Err("\{key} must be an array of numbers")
              }
            }
            if key == "good_quality" {
              out.good_quality = numbers
            } else {
              out.suspicious = numbers
            }
          }
          _ => return Err("\{key} must be an array of numbers")
        }
      "good_status" =>
        match raw.get(key) {
          Some(Array(items)) => {
            let texts : Array[String] = []
            for item in items {
              match item {
                String(text) => texts.push(text)
                _ => return Err("good_status must be an array of strings")
              }
            }
            out.good_status = texts
          }
          _ => return Err("good_status must be an array of strings")
        }
      "emit_all" =>
        match raw.get(key) {
          Some(True) => out.emit_all = true
          Some(False) => out.emit_all = false
          _ => return Err("emit_all must be a boolean")
        }
      _ => return Err("unknown config key \{key}")
    }
  }
  if out.alarm_minutes < out.notice_minutes {
    return Err("alarm_minutes must be >= notice_minutes")
  }
  Ok(out)
}

///|
/// One parsed row of a poll.
priv struct Row {
  node : String
  value : Double
  ts_ms : Int64
  ts_text : String
}

///|
/// Reads one row object. `quality`/`status` gate the SAMPLE: a bad sample is
/// neither "changed" nor "unchanged" — it is not evidence either way, so the
/// caller skips it (returning None) rather than letting it break a flat run.
fn row_of(cfg : StuckConfig, obj : Json) -> Result[Row?, String] {
  let node = match obj.value(cfg.node_field) {
    Some(String(text)) => text
    _ => return Err("row has no \{cfg.node_field}")
  }
  let value = match obj.value(cfg.value_field) {
    Some(Number(n)) => n
    _ => return Err("row for \{node} has no numeric \{cfg.value_field}")
  }
  let (ts_ms, ts_text) = match obj.value(cfg.ts_field) {
    Some(String(text)) =>
      match @sdk.parse_iso8601_ms(text) {
        Ok(ms) => (ms, text)
        Err(e) => return Err("row for \{node}: \{e}")
      }
    _ => return Err("row for \{node} has no \{cfg.ts_field} string")
  }
  if cfg.good_quality.length() > 0 {
    match obj.value(cfg.quality_field) {
      Some(Number(q)) => if !cfg.good_quality.contains(q) { return Ok(None) }
      None => ()
      Some(_) => return Ok(None)
    }
  }
  if cfg.good_status.length() > 0 {
    match obj.value(cfg.status_field) {
      Some(String(text)) =>
        if !cfg.good_status.contains(text) {
          return Ok(None)
        }
      None => ()
      Some(_) => return Ok(None)
    }
  }
  Ok(Some(Row::{ node, value, ts_ms, ts_text, }))
}

///|
/// Every row in a record's value: a JSON array (a poll's reply) or one object.
fn rows_of(cfg : StuckConfig, value : Bytes) -> Result[Array[Row], String] {
  let text = @utf8.decode_lossy(value[0:value.length()])
  let parsed = match (try? @json.parse(text)) {
    Ok(json) => json
    Err(e) => return Err("record value is not JSON: \{e}")
  }
  let out : Array[Row] = []
  let items : Array[Json] = match parsed {
    Array(items) => items
    Object(_) => [parsed]
    _ => return Err("record value must be a JSON array or object")
  }
  for item in items {
    match row_of(cfg, item) {
      Ok(Some(row)) => out.push(row)
      Ok(None) => () // a bad-quality sample: skipped
      Err(e) => return Err(e) // a malformed row: refused
    }
  }
  Ok(out)
}

///|
/// A node's sticky state, as the `k=v;` text kept in the state topic.
priv struct NodeState {
  mut runs : Int64 // completed runs (for calibration)
  mut over_notice : Int64 // completed runs that passed the notice line
  mut over_alarm : Int64 // completed runs that passed the alarm line
  mut gaps : Int64 // data gaps this run has spanned (a gap is not a flat period,
  //                  but it must not hide one either: see the header)
  mut value : Double
  mut value_set : Bool
  mut start_ms : Int64
  mut last_ms : Int64
  mut alert : Bool
  mut alert_value : Double
  mut changed_ms : Int64
  mut emit_ms : Int64
  mut verdict : String
}

///|
/// A fresh node: no run yet, no alert, no counters.
fn new_node_state() -> NodeState {
  NodeState::{
    runs: 0L,
    over_notice: 0L,
    over_alarm: 0L,
    gaps: 0L,
    value: 0.0,
    value_set: false,
    start_ms: 0L,
    last_ms: 0L,
    alert: false,
    alert_value: 0.0,
    changed_ms: 0L,
    emit_ms: 0L,
    verdict: "",
  }
}

///|
fn parse_state(text : String) -> NodeState {
  let st = new_node_state()
  for part in text.split(";") {
    let pair = match part.find("=") {
      Some(idx) =>
        (part[0:idx].to_owned(), part[idx + 1:part.length()].to_owned())
      None => continue
    }
    let (key, value) = pair
    let num = try? @string.parse_double(value)
    match key {
      "n" => st.runs = num.unwrap_or(0.0).to_int64()
      "over_n" => st.over_notice = num.unwrap_or(0.0).to_int64()
      "over_a" => st.over_alarm = num.unwrap_or(0.0).to_int64()
      "gaps" => st.gaps = num.unwrap_or(0.0).to_int64()
      "v" =>
        match num {
          Ok(n) => {
            st.value = n
            st.value_set = true
          }
          Err(_) => ()
        }
      "start" => st.start_ms = num.unwrap_or(0.0).to_int64()
      "last" => st.last_ms = num.unwrap_or(0.0).to_int64()
      "alert" => st.alert = value == "1"
      "alertv" => st.alert_value = num.unwrap_or(0.0)
      "changed" => st.changed_ms = num.unwrap_or(0.0).to_int64()
      "emit" => st.emit_ms = num.unwrap_or(0.0).to_int64()
      "verdict" => st.verdict = value
      _ => ()
    }
  }
  st
}

///|
fn state_text(st : NodeState) -> String {
  let buffer = StringBuilder::new()
  buffer.write_string(
    "n=\{st.runs};over_n=\{st.over_notice};over_a=\{st.over_alarm};",
  )
  buffer.write_string("v=\{st.value};start=\{st.start_ms};last=\{st.last_ms};")
  buffer.write_string(
    "alert=\{if st.alert { 1 } else { 0 }};alertv=\{st.alert_value};",
  )
  buffer.write_string(
    "changed=\{st.changed_ms};emit=\{st.emit_ms};verdict=\{st.verdict}",
  )
  buffer.to_string()
}

///|
fn verdict_of(
  cfg : StuckConfig,
  flat_minutes : Double,
  suspicious : Bool,
) -> String {
  if suspicious || flat_minutes >= cfg.alarm_minutes {
    "STUCK"
  } else if flat_minutes >= cfg.notice_minutes {
    "NOTICE"
  } else if flat_minutes >= cfg.window_minutes {
    "FLAT"
  } else {
    // the window contains a change: this is the "is it flat in the last N
    // minutes" question, answered
    "OK"
  }
}

///|
fn decision_json(
  node : String,
  verdict : String,
  value : Double,
  flat_minutes : Double,
  at_text : String,
  st : NodeState,
  reason : String,
) -> String {
  "{\"node\":\"" +
  node +
  "\",\"verdict\":\"" +
  verdict +
  "\",\"value\":" +
  value.to_string() +
  ",\"flat_minutes\":" +
  flat_minutes.to_string() +
  ",\"at\":\"" +
  at_text +
  "\",\"runs\":" +
  st.runs.to_string() +
  ",\"over_alarm\":" +
  st.over_alarm.to_string() +
  ",\"gaps\":" +
  st.gaps.to_string() +
  ",\"reason\":\"" +
  reason +
  "\"}"
}

///|
pub fn mf_op_abi_version() -> Int32 {
  @sdk.abi_version()
}

///|
pub fn mf_op_alloc_input(len : Int32) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_init(config : Bytes) -> Int32 {
  match parse_config(config) {
    Ok(cfg) => {
      config_cell.cfg = Some(cfg)
      0
    }
    Err(_) => -1
  }
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "stuck",
    process: fn(_records) {
      Err(
        "this operator keeps state: it is called through mf_op_state_apply (ABI v3), not mf_op_process",
      )
    },
  }
  let _ = @sdk.run_buffered(refusing, input)
  @sdk.buffered_output()
}

///|
pub fn mf_op_output_len() -> Int32 {
  @sdk.output_len()
}

///|
pub fn mf_op_last_status() -> Int32 {
  @sdk.last_status()
}

///|
pub fn mf_op_last_error() -> Bytes {
  @sdk.last_error_bytes()
}

///|
pub fn mf_op_state_abi_version() -> Int32 {
  @sdk.state_abi_version()
}

///|
/// The whole operator: fold each batch of polls into the per-node state, emit a
/// decision when there is something to say.
pub fn mf_op_state_apply(input : Bytes) -> Bytes {
  let run = @sdk.GuestStatefulOperator::{
    name: "stuck",
    process: fn(state_in, records) {
      // the config arrives through mf_op_init (the guest has no other channel)
      let cfg = match active_config() {
        Ok(cfg) => cfg
        Err(e) => return Err(e)
      }
      let states : Map[String, NodeState] = {}
      for entry in state_in {
        let key = match (try? @utf8.decode(entry.key[0:entry.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let value = match
          (try? @utf8.decode(entry.value[0:entry.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value for \{key} is not UTF-8 text")
        }
        states[key] = parse_state(value)
      }
      let out : Array[@protocol.Record] = []
      // every node TOUCHED in this call needs its state written back, not just
      // the ones seen for the first time: with the latter, the second and every
      // later call would report an empty update set and the state topic would
      // freeze at the first batch (measured — on a 4-day replay the counters
      // stopped at n=6, which is exactly one call's worth)
      let touched : Array[String] = []
      let touched_set : Map[String, Bool] = {}
      let updates : Array[@operator.StateEntry] = []
      for r in records {
        let rows = match rows_of(cfg, r.value) {
          Ok(rows) => rows
          Err(e) => return Err(e)
        }
        for row in rows {
          let st = match states.get(row.node) {
            Some(st) => st
            None => {
              let fresh = new_node_state()
              states[row.node] = fresh
              fresh
            }
          }
          match touched_set.get(row.node) {
            Some(_) => ()
            None => {
              touched_set[row.node] = true
              touched.push(row.node)
            }
          }
          // a polling source re-delivers the same row until it is asked for
          // something newer: anything at or before the watermark is old news
          if st.last_ms > 0L && row.ts_ms <= st.last_ms {
            continue
          }
          let node = row.node
          let mut emit_kind = ""
          let mut reason = ""
          let mut flat_minutes = 0.0
          let mut verdict = ""
          let gap = if st.last_ms > 0L { row.ts_ms - st.last_ms } else { 0L }
          let changed = st.value_set &&
            (row.value - st.value).abs() > cfg.deadband
          // A CHANGE comes first, gap or no gap. This order is a fix, not a
          // preference: with the gap check first, a value that changed across a
          // gap kept the STALE value and the new run was never started
          // (measured by the gate: a run that had just begun reported flat=19
          // minutes). A change is a change whether or not we saw the minutes in
          // between.
          if changed || !st.value_set {
            // the run that just ended, if it lasted long enough to count
            if st.value_set && st.last_ms > st.start_ms && st.gaps == 0L {
              st.runs += 1L
              let closed = (st.last_ms - st.start_ms).to_double() / 60000.0
              if closed >= cfg.alarm_minutes {
                st.over_alarm += 1L
              }
              if closed >= cfg.notice_minutes {
                st.over_notice += 1L
              }
            }
            st.start_ms = row.ts_ms
            st.value = row.value
            st.value_set = true
            st.gaps = 0L
            flat_minutes = 0.0
            verdict = "OK"
            reason = "值变为 \{row.value}，本段重新起算"
            emit_kind = "verdict"
          } else {
            if gap > cfg.max_gap_ms {
              // A gap is NOT a flat period — but breaking the run on it is worse:
              // a five-minute hole inside a four-hour stuck episode would hide it
              // (measured: the naive break turned four >150-minute runs into
              // three). So the run continues, the gap is counted, and the
              // decision says the run spanned one.
              st.gaps += 1L
              verdict = "NO_DATA"
              reason = "取数断流 \{gap}ms（上限 \{cfg.max_gap_ms}ms）；本段继续累计并记下这次断流"
              emit_kind = "no_data"
            }
            // the gap is this row's news: the run keeps its length (a hole must
            // not erase a four-hour flat period) but the verdict is not
            // recomputed from a row we cannot fully vouch for. The next row
            // resumes normal verdicts.
            if emit_kind == "no_data" {
              flat_minutes = (row.ts_ms - st.start_ms).to_double() / 60000.0
            } else {
              flat_minutes = (row.ts_ms - st.start_ms).to_double() / 60000.0
              let suspicious = cfg.suspicious.contains(row.value)
              verdict = verdict_of(cfg, flat_minutes, suspicious)
              if verdict == "STUCK" {
                reason = if suspicious {
                  "值 \{row.value} 在可疑值清单里（满量程/故障形态），已持续 \{flat_minutes} 分钟"
                } else {
                  "恒值已持续 \{flat_minutes} 分钟（告警线 \{cfg.alarm_minutes} 分钟），末值 \{row.value}"
                }
              } else if verdict == "NOTICE" {
                reason = "窗口内恒定为 \{row.value}，已持续 \{flat_minutes} 分钟（提示线 \{cfg.notice_minutes} 分钟）"
              } else if verdict == "OK" {
                reason = "窗口（\{cfg.window_minutes} 分钟）内有变化，值在动（末值 \{row.value}）"
              } else {
                reason = "恒值段 \{flat_minutes} 分钟（窗口 \{cfg.window_minutes} 分钟），末值 \{row.value}"
              }
              emit_kind = if verdict == "STUCK" { "stuck" } else { "verdict" }
              // ---- the alert latch, and the hysteresis on clearing it
              if verdict == "STUCK" && !st.alert {
                st.alert = true
                st.alert_value = row.value
                st.changed_ms = 0L
              } else if st.alert {
                if (row.value - st.alert_value).abs() > cfg.deadband {
                  if st.changed_ms == 0L {
                    st.changed_ms = row.ts_ms
                  } else if (row.ts_ms - st.changed_ms).to_double() >=
                    cfg.clear_minutes * 60000.0 {
                    st.alert = false
                    st.changed_ms = 0L
                    emit_kind = "cleared"
                    reason = "已恢复（离开 \{st.alert_value} 超过 \{cfg.clear_minutes} 分钟）：\{reason}"
                  }
                } else {
                  // back at the stuck value: the excursion did not hold
                  st.changed_ms = 0L
                }
              }
            }
          }
          let changed_verdict = verdict != st.verdict
          let heartbeat_due = st.emit_ms > 0L &&
            (row.ts_ms - st.emit_ms).to_double() >=
            cfg.heartbeat_minutes * 60000.0
          if emit_kind == "no_data" ||
            emit_kind == "cleared" ||
            changed_verdict ||
            heartbeat_due ||
            st.emit_ms == 0L ||
            cfg.emit_all {
            out.push(@protocol.Record::{
              timestamp: r.timestamp,
              key: @utf8.encode(node),
              value: @utf8.encode(
                decision_json(
                  node,
                  verdict,
                  row.value,
                  flat_minutes,
                  row.ts_text,
                  st,
                  reason,
                ),
              ),
              headers: r.headers,
            })
            st.emit_ms = row.ts_ms
          }
          st.verdict = verdict
          st.last_ms = row.ts_ms
          states[node] = st // 写回：不依赖结构引用语义
          updates.push(@operator.StateEntry::{
            key: @utf8.encode(node),
            value: @utf8.encode(state_text(st)),
          })
        }
      }
      // one state entry per node per call: a fold over an ordered batch means
      // the LAST write is the state, so earlier ones are dropped here
      let final_updates : Array[@operator.StateEntry] = []
      for node in touched {
        let entry : @operator.StateEntry = {
          key: @utf8.encode(node),
          value: @utf8.encode(state_text(states[node])),
        }
        final_updates.push(entry)
      }
      Ok((final_updates, out))
    },
  }
  let _ = @sdk.run_stateful(run, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
