// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the running-average operator.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"field": "speed"}
//   {"field": "tips", "emit": "avg_tip", "count_field": "trips"}
//
// The state value is `<sum>,<count>` as decimal text — two numbers, not a
// pre-divided average: an average that only remembers itself cannot be
// corrected, and a running mean updated in place drifts. Sum and count are
// both exact inputs to the division.
//
// Input: records keyed by whatever the average is per (vehicle, zone, colour
// — the key is the group) whose value carries `field` as a number.
// Output: one record per input record:
//   {"key":"<the group>","<emit>":<running average>,"<count_field>":<n>}
// so the LAST record for a group in a window carries that window's average,
// and the state topic holds the rest (the same carrier choice the counter
// makes, for the same reason: there is no window-close trigger to emit on).
//
// A record whose `field` is missing or not a number is REFUSED, not skipped:
// the chain is supposed to have cleaned incomplete events (see the helsinki
// example's predicates), and quietly averaging over a subset while claiming
// to average over the stream is the kind of wrong that looks right.

///|
priv struct AverageState {
  mut field : String
  mut emit : String
  mut count_field : String
}

///|
let state : AverageState = AverageState::{
  field: "",
  emit: "avg",
  count_field: "count",
}

///|
/// Parses `"<sum>,<count>"` back into its two numbers.
fn parse_state_value(
  text : String,
  key : String,
) -> Result[(Double, Int), String] {
  // split returns an iterator, and a state value with the wrong number of
  // fields is a corrupted key: count the parts instead of pretending the
  // first two are the pair
  let mut parts = 0
  let mut sum_text = ""
  let mut count_text = ""
  for piece in text.split(",") {
    let part = piece.to_owned()
    parts = parts + 1
    if parts == 1 {
      sum_text = part
    } else if parts == 2 {
      count_text = part
    }
  }
  if parts != 2 {
    return Err("state for \{key} is not a sum,count pair (\{text})")
  }
  let sum = match (try? @string.parse_double(sum_text)) {
    Ok(d) => d
    Err(_) => return Err("state sum for \{key} is not a number (\{sum_text})")
  }
  let count = match (try? @string.parse_int(count_text)) {
    Ok(n) => n
    Err(_) =>
      return Err("state count for \{key} is not a number (\{count_text})")
  }
  Ok((sum, count))
}

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_init(config : Bytes) -> Int {
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "field" | "emit" | "count_field" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "field") {
    Some(f) => {
      if f.length() == 0 {
        return -1
      }
      state.field = f
    }
    None => return -1
  }
  for pair in [("emit", "emit"), ("count_field", "count_field")] {
    match cfg.get(pair.0) {
      None => ()
      Some(_) =>
        match @sdk.config_string(cfg, pair.0) {
          Some(text) =>
            if text.length() == 0 {
              return -1
            } else if pair.0 == "emit" {
              state.emit = text
            } else {
              state.count_field = text
            }
          None => return -1
        }
    }
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "average",
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
pub fn mf_op_output_len() -> Int {
  @sdk.output_len()
}

///|
pub fn mf_op_last_status() -> Int {
  @sdk.last_status()
}

///|
pub fn mf_op_last_error() -> Bytes {
  @sdk.last_error_bytes()
}

///|
pub fn mf_op_state_abi_version() -> Int {
  @sdk.state_abi_version()
}

///|
pub fn mf_op_state_apply(input : Bytes) -> Bytes {
  let average = @sdk.GuestStatefulOperator::{
    name: "average",
    process: fn(state_in, records) {
      let sums : Map[String, Double] = {}
      let counts : Map[String, Int] = {}
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let v = match (try? @utf8.decode(e.value[0:e.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value is not UTF-8 text")
        }
        let (sum, count) = match parse_state_value(v, k) {
          Ok(pair) => pair
          Err(e) => return Err(e)
        }
        sums[k] = sum
        counts[k] = count
      }
      let order : Array[String] = []
      let out : Array[@protocol.Record] = []
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "an average needs a key on every record (the group to average over)",
          )
        }
        let key = @utf8.decode_lossy(r.key[0:r.key.length()])
        let x = match @sdk.json_field(r.value, state.field) {
          Ok(Some(@sdk.ScalarNumber(d))) => d
          Ok(Some(_)) =>
            return Err("field \{state.field} is not a number for key \{key}")
          Ok(None) =>
            return Err(
              "field \{state.field} is missing for key \{key}; clean the stream before averaging it",
            )
          Err(e) => return Err(e)
        }
        let sum = match sums.get(key) {
          Some(s) => s + x
          None => {
            order.push(key)
            x
          }
        }
        let count = (match counts.get(key) {
            Some(n) => n
            None => 0
          }) +
          1
        sums[key] = sum
        counts[key] = count
        let mean = sum / count.to_double()
        let answer = "{\"key\":\"" +
          key +
          "\",\"" +
          state.emit +
          "\":" +
          mean.to_string() +
          ",\"" +
          state.count_field +
          "\":" +
          count.to_string() +
          "}"
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value: @utf8.encode(answer),
          headers: r.headers,
        })
      }
      // one write per group, not per record: the host applies entries in
      // order and the last write wins
      let updates : Array[@operator.StateEntry] = []
      for k in order {
        let sum = match sums.get(k) {
          Some(s) => s
          None => 0.0
        }
        let count = match counts.get(k) {
          Some(n) => n
          None => 0
        }
        updates.push(@operator.StateEntry::{
          key: @utf8.encode(k),
          value: @utf8.encode(sum.to_string() + "," + count.to_string()),
        })
      }
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(average, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
