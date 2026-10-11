// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the key-from-field mapper.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"field": "event_name"}
//   {"field": "event_name", "map": {"AnalyticsSessionStart": "session_start"}}
//   {"field": "event_name", "map": {...}, "default": "other"}
//
// Precedence is map, then default, then the field value itself. The order
// matters: a table is the caller saying "these are the names I care about",
// and a default is how it says what the rest are called. Without a default,
// a value that is not in the table keeps its own name — which is the honest
// behaviour for a key that is really just a field, and the reason
// `default` is optional rather than required.
//
// A missing field (or a value that is not a JSON object) is refused by name
// unless a default was configured: silently keying by "nothing" would put
// unrelated records in one bucket, which is the failure mode state makes
// expensive.

///|
priv struct KeyFieldState {
  mut field : String
  mut default : String
  mut has_default : Bool
  labels : Map[String, String]
}

///|
let state : KeyFieldState = KeyFieldState::{
  field: "",
  default: "",
  has_default: false,
  labels: {},
}

///|
fn field_text(value : Bytes, field : String) -> Result[String, String] {
  // one field, read without parsing the whole document: a key mapper runs
  // once per record, and a full parse per record is what exhausted the wasm
  // fuel budget on a 183-record batch (see apps/operator-sdk/json_field.mbt)
  match @sdk.json_field(value, field) {
    Ok(Some(@sdk.ScalarText(text))) => Ok(text)
    Ok(Some(@sdk.ScalarNumber(d))) => {
      let n = d.to_int64()
      if n.to_double() == d {
        Ok(n.to_string())
      } else {
        Err("field \{field} is not an integer; keys are text")
      }
    }
    Ok(Some(@sdk.ScalarBool(b))) => Ok(b.to_string())
    Ok(Some(@sdk.ScalarNull)) => Err("field \{field} is null")
    Ok(None) => Err("field \{field} is missing")
    Err(e) => Err(e)
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
      "field" | "map" | "default" => ()
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
  match cfg.get("default") {
    None => ()
    Some(String(d)) => {
      if d.length() == 0 {
        return -1
      }
      state.default = d
      state.has_default = true
    }
    Some(_) => return -1
  }
  match cfg.get("map") {
    None => ()
    Some(Object(table)) =>
      for pair in table {
        match pair.1 {
          String(label) =>
            if label.length() == 0 {
              return -1
            } else {
              state.labels[pair.0] = label
            }
          _ => return -1
        }
      }
    Some(_) => return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let keyer = @sdk.GuestOperator::{
    name: "keyfield",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let label = match field_text(r.value, state.field) {
          Ok(text) =>
            match state.labels.get(text) {
              Some(label) => label
              None =>
                // an unmapped value is exactly what `default` is for (the
                // reference's `_ => "other"`); without a default the value
                // keeps its own name
                if state.has_default {
                  state.default
                } else {
                  text
                }
            }
          Err(e) =>
            if state.has_default {
              state.default
            } else {
              return Err(e)
            }
        }
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: @utf8.encode(label),
          value: r.value,
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(keyer, input)
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
