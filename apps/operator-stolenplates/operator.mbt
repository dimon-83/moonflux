// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the stolen-plate check.
//
// Config: `{}`. The table comes from the state topic (loaded by
// apps/operator-loadtable, whose values are `{"maker":...,"model":...}`).
//
// Semantics, exactly the reference's: a car whose plate is in the registered
// table but whose maker/model differ from the registered ones is carrying a
// stolen plate — the plate is real, the car is not. A car whose plate is not
// in the table is simply unregistered and not reported (SDF returns None
// there too).
//
// The operator is READ-ONLY: it returns no state updates. A check that wrote
// would let a reader corrupt the table it is checking against.
//
// Input: records keyed by license whose value is the car JSON
//   {"maker":...,"model":...,"license":...,"location":...,"mph":N}
// State in: for the plates in this batch, `{"maker":...,"model":...}`
// Output: one record per mismatch:
//   {"license":X,"owner":"<car maker> <car model>","violator":"<registered>"}

///|
fn json_escape(text : String) -> String {
  let out = StringBuilder::new()
  for ch in text {
    match ch {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\t' => out.write_string("\\t")
      '\r' => out.write_string("\\r")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn text_field(value : Bytes, field : String) -> Result[String, String] {
  match @sdk.json_field(value, field) {
    Ok(Some(@sdk.ScalarText(text))) => Ok(text)
    Ok(Some(_)) => Err("field \{field} is not text")
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
  match @sdk.parse_config(config) {
    Ok(cfg) => if cfg.length() == 0 { 0 } else { -1 }
    Err(_) => -1
  }
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "stolenplates",
    process: fn(_records) {
      Err(
        "this operator reads state: it is called through mf_op_state_apply (ABI v3), not mf_op_process",
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
  let check = @sdk.GuestStatefulOperator::{
    name: "stolenplates",
    process: fn(state_in, records) {
      // the registered table, keyed by plate
      let registered : Map[String, (String, String)] = {}
      for e in state_in {
        let plate = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let row = @utf8.decode_lossy(e.value[0:e.value.length()])
        let maker = match @sdk.json_field(@utf8.encode(row), "maker") {
          Ok(Some(@sdk.ScalarText(text))) => text
          _ => ""
        }
        let model = match @sdk.json_field(@utf8.encode(row), "model") {
          Ok(Some(@sdk.ScalarText(text))) => text
          _ => ""
        }
        registered[plate] = (maker, model)
      }
      let out : Array[@protocol.Record] = []
      for r in records {
        let license = match text_field(r.value, "license") {
          Ok(text) => text
          Err(e) => return Err(e)
        }
        // the record's key is the plate when a keyer ran, and the lookup is
        // by plate either way
        let plate = if r.key.length() > 0 {
          @utf8.decode_lossy(r.key[0:r.key.length()])
        } else {
          license
        }
        match registered.get(plate) {
          None => () // unregistered: the reference reports nothing
          Some(pair) => {
            let maker = match text_field(r.value, "maker") {
              Ok(text) => text
              Err(e) => return Err(e)
            }
            let model = match text_field(r.value, "model") {
              Ok(text) => text
              Err(e) => return Err(e)
            }
            if maker != pair.0 || model != pair.1 {
              let answer = "{\"license\":\"" +
                json_escape(license) +
                "\",\"owner\":\"" +
                json_escape(maker + " " + model) +
                "\",\"violator\":\"" +
                json_escape(pair.0 + " " + pair.1) +
                "\"}"
              out.push(@protocol.Record::{
                timestamp: r.timestamp,
                key: r.key,
                value: @utf8.encode(answer),
                headers: r.headers,
              })
            }
          }
        }
      }
      let none : Array[@operator.StateEntry] = []
      Ok((none, out))
    },
  }
  let _ = @sdk.run_stateful(check, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
