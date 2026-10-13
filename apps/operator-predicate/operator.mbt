// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the JSON predicate filter.
//
// Config (through mf_op_init; unknown keys and unknown operators are
// refused):
//   {"field": "overdraft", "op": "eq", "value": true}
//   {"field": "mph", "op": "gt", "value": 60, "missing": "drop"}
//
// `op` is one of lt le gt ge eq ne. `value` must be a number, a string or a
// boolean. `missing` decides what a record whose field is absent (or whose
// value is not JSON) does: "drop" (default) or "keep". Both are legitimate —
// "keep" is how a filter says "I only know how to judge the records that
// have this field", and making the caller choose beats guessing.
//
// Why this exists: a selection has to be a *structural* judgement about the
// record. Matching a substring of the JSON text works only while nobody
// reorders the fields or changes whitespace, and the difference between a
// real predicate and a lucky substring is exactly the kind of thing that
// passes a gate once and fails in production.

///|
priv struct PredicateState {
  mut field : String
  mut op : String
  mut number : Double
  mut text : String
  mut boolean : Bool
  mut kind : Int32 // 0 = number, 1 = text, 2 = bool
  mut keep_missing : Bool
}

///|
let state : PredicateState = PredicateState::{
  field: "",
  op: "",
  number: 0.0,
  text: "",
  boolean: false,
  kind: 0,
  keep_missing: false,
}

///|

///|
/// True when the record satisfies the predicate; `None` when the field is
/// absent (the caller decides with `missing`).
fn satisfies(value : Bytes) -> Result[Bool?, String] {
  match @sdk.json_field(value, state.field) {
    Err(e) => Err(e)
    Ok(None) => Ok(None)
    Ok(Some(@sdk.ScalarNull)) => Ok(Some(false))
    Ok(Some(@sdk.ScalarNumber(n))) =>
      if state.kind != 0 {
        Ok(Some(false))
      } else {
        Ok(
          Some(
            match state.op {
              "lt" => n < state.number
              "le" => n <= state.number
              "gt" => n > state.number
              "ge" => n >= state.number
              "eq" => n == state.number
              "ne" => n != state.number
              _ => return Err("unknown operator \{state.op}")
            },
          ),
        )
      }
    Ok(Some(@sdk.ScalarText(text))) =>
      if state.kind != 1 {
        Ok(Some(false))
      } else {
        match state.op {
          "eq" => Ok(Some(text == state.text))
          "ne" => Ok(Some(text != state.text))
          _ => Err("operator \{state.op} does not apply to text")
        }
      }
    Ok(Some(@sdk.ScalarBool(b))) =>
      if state.kind != 2 {
        Ok(Some(false))
      } else {
        match state.op {
          "eq" => Ok(Some(b == state.boolean))
          "ne" => Ok(Some(b != state.boolean))
          _ => Err("operator \{state.op} does not apply to booleans")
        }
      }
  }
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
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "field" | "op" | "value" | "missing" => ()
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
  match @sdk.config_string(cfg, "op") {
    Some(op) =>
      match op {
        "lt" | "le" | "gt" | "ge" | "eq" | "ne" => state.op = op
        _ => return -1
      }
    None => return -1
  }
  match cfg.get("value") {
    Some(Number(d)) => {
      state.kind = 0
      state.number = d
    }
    Some(String(s)) => {
      state.kind = 1
      state.text = s
    }
    Some(True) => {
      state.kind = 2
      state.boolean = true
    }
    Some(False) => {
      state.kind = 2
      state.boolean = false
    }
    _ => return -1
  }
  match cfg.get("missing") {
    None => state.keep_missing = false
    Some(String("drop")) => state.keep_missing = false
    Some(String("keep")) => state.keep_missing = true
    Some(_) => return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let predicate = @sdk.GuestOperator::{
    name: "predicate",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let verdict = match satisfies(r.value) {
          Ok(Some(b)) => b
          // the field is absent (or the value is not a JSON object): the
          // caller said what to do with a record the predicate cannot see
          Ok(None) => state.keep_missing
          Err(_) => state.keep_missing
        }
        if verdict {
          out.push(r)
        }
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(predicate, input)
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
fn main {
  let _ = mf_op_abi_version()
}
