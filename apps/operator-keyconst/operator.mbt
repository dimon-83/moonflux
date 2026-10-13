// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the constant-key stamper.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"key": "sentences"}
//
// Every record leaves with that key and its value untouched. Use it when the
// next operator's state is a GLOBAL accumulator: the host hands a guest the
// state for the keys in its batch, so "one accumulator" means "one key".

///|
priv struct KeyConstState {
  mut key : String
}

///|
let state : KeyConstState = KeyConstState::{ key: "", }

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
      "key" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "key") {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.key = text
    }
    None => return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let stamper = @sdk.GuestOperator::{
    name: "keyconst",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: @utf8.encode(state.key),
          value: r.value,
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(stamper, input)
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
