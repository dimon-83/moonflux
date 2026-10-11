// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the tumbling-window keyer.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"window_ms": 60000}                       width in ms (required, > 0)
//   {"window_ms": 60000, "time_field": "ts"}   event time from the value's JSON
//   {"window_ms": 60000, "time_field": "ts", "key_field": "user"}
//
// Each record's key becomes `key@<window_start>` where window_start is the
// event time floored to the width. An empty key keeps just the window
// start, which is the honest spelling of "one global window per bucket".
//
// Windowing in moonflux is not a second stateful concept: it is a KEY SHAPE.
// State is keyed by the record key, so rewriting the key makes every window
// its own state entry — which is why windows need no new ABI, no host
// support, and no timer (P30/T114, docs/operator-abi-v3-state.md §5).
//
// `time_field` exists because a file source stamps every record with one
// read-time timestamp: a data file whose rows carry their own event time is
// the normal case (the SDF examples' JSON is exactly that), and a keyer
// that could only read the log's timestamp would put a whole file in one
// window. `key_field` does the same for sources that carry the partitioning
// key inside the value instead of in the record key.
//
// What this deliberately does NOT do: there is no idle trigger and no
// processing-time advance. A window exists because a record arrived for it,
// and it stops changing when no more records arrive for it. A pipeline with
// no traffic has nothing to close — that boundary is documented rather than
// papered over with a timer (the kernel has no clock to begin with).
//
// Timestamps must be non-negative: a negative event time has no meaningful
// floor here, and refusing it by name beats a window start nobody can
// explain.

///|
priv struct TumbleState {
  mut window_ms : Int64
  /// "" = use the record's own timestamp (the log's event-time column)
  mut time_field : String
  /// "" = keep the record's key
  mut key_field : String
}

///|
let state : TumbleState = TumbleState::{
  window_ms: 0L,
  time_field: "",
  key_field: "",
}

///|
/// Reads a numeric JSON field out of a record's value. A missing field or a
/// non-number is a named refusal: silently windowing on the read-time
/// timestamp would produce plausible-looking wrong buckets.
fn field_int64(value : Bytes, field : String) -> Result[Int64, String] {
  let text = @utf8.decode_lossy(value[0:value.length()])
  let parsed = match (try? @json.parse(text)) {
    Ok(json) => json
    Err(_) => return Err("value is not JSON, so \{field} cannot be read")
  }
  let obj = match parsed {
    Object(obj) => obj
    _ => return Err("value is not a JSON object, so \{field} cannot be read")
  }
  match obj.get(field) {
    Some(Number(d)) => Ok(d.to_int64())
    Some(_) => Err("field \{field} is not a number")
    None => Err("field \{field} is missing from the value")
  }
}

///|
/// Reads a text JSON field out of a record's value (a key that lives in the
/// payload rather than in the record key).
fn field_text(value : Bytes, field : String) -> Result[String, String] {
  let text = @utf8.decode_lossy(value[0:value.length()])
  let parsed = match (try? @json.parse(text)) {
    Ok(json) => json
    Err(_) => return Err("value is not JSON, so \{field} cannot be read")
  }
  let obj = match parsed {
    Object(obj) => obj
    _ => return Err("value is not a JSON object, so \{field} cannot be read")
  }
  match obj.get(field) {
    Some(String(s)) => Ok(s)
    Some(Number(d)) => Ok(d.to_int64().to_string())
    Some(_) => Err("field \{field} is not text")
    None => Err("field \{field} is missing from the value")
  }
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
      "window_ms" | "time_field" | "key_field" => ()
      _ => return -1
    }
  }
  match @sdk.config_int(cfg, "window_ms") {
    Some(ms) => {
      if ms <= 0 {
        return -1
      }
      state.window_ms = ms.to_int64()
    }
    None => return -1
  }
  let time_field = match cfg.get("time_field") {
    None => None
    Some(_) => @sdk.config_string(cfg, "time_field")
  }
  match time_field {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.time_field = text
    }
    None => ()
  }
  let key_field = match cfg.get("key_field") {
    None => None
    Some(_) => @sdk.config_string(cfg, "key_field")
  }
  match key_field {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.key_field = text
    }
    None => ()
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let tumbler = @sdk.GuestOperator::{
    name: "tumble",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let ts = if state.time_field == "" {
          r.timestamp
        } else {
          match field_int64(r.value, state.time_field) {
            Ok(ts) => ts
            Err(e) => return Err(e)
          }
        }
        if ts < 0L {
          return Err("tumble needs non-negative event timestamps (got \{ts})")
        }
        let start = ts / state.window_ms * state.window_ms
        let base = if state.key_field == "" {
          @utf8.decode_lossy(r.key[0:r.key.length()])
        } else {
          match field_text(r.value, state.key_field) {
            Ok(text) => text
            Err(e) => return Err(e)
          }
        }
        // the key stays readable: `word@60000`, not a hash of the pair
        let key = if base.length() == 0 {
          @utf8.encode(start.to_string())
        } else {
          @utf8.encode(base + "@" + start.to_string())
        }
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key,
          value: r.value,
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(tumbler, input)
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
fn main {
  let _ = mf_op_abi_version()
}
