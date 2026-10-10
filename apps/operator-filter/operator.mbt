// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the config-driven filter operator.
//
// Why this module exists: SDF's `filter` and `filter-map` primitives are
// 1 -> 0 and 1 -> 1 decisions written inside Rust SmartModules. The same
// decision has no spelling in an mbel expression transform, because a
// rule must return a string — so here it belongs to the sandbox, where
// the operator contract (`Array[Record] -> Array[Record]`) makes
// "drop it" a shorter batch, a structural fact rather than a convention.
//
// Config (through mf_op_init; the host never interprets it — decisions
// 15 / 50):
//   {}                     keep everything (identity)
//   {"min_len": 10}        keep values at least 10 bytes long
//   {"contains": "ERROR"}  keep values containing that substring
// Rules given together must all hold. Unknown keys are refused at init
// rather than ignored: a config that says something the operator will
// not do is a lie to whoever wrote the spec.
//
// Length is byte length (the values here are treated as opaque payload,
// which is what the wire carries); a multi-byte text filter would want a
// character count and would say so in its own module.

///|
priv struct FilterState {
  mut min_len : Int
  mut has_len : Bool
  mut needle : String
  mut has_needle : Bool
}

///|
let state : FilterState = FilterState::{
  min_len: 0,
  has_len: false,
  needle: "",
  has_needle: false,
}

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
}

///|
pub fn mf_op_init(config : Bytes) -> Int {
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "min_len" | "contains" => ()
      _ => return -1
    }
  }
  state.has_len = false
  state.has_needle = false
  if cfg.get("min_len") is Some(_) {
    match @sdk.config_int(cfg, "min_len") {
      Some(n) => {
        if n < 0 {
          return -1
        }
        state.min_len = n
        state.has_len = true
      }
      None => return -1
    }
  }
  if cfg.get("contains") is Some(_) {
    match @sdk.config_string(cfg, "contains") {
      Some(s) => {
        state.needle = s
        state.has_needle = true
      }
      None => return -1
    }
  }
  0
}

///|
fn keeps(value : String) -> Bool {
  if state.has_len && value.length() < state.min_len {
    return false
  }
  if state.has_needle && !value.contains(state.needle) {
    return false
  }
  true
}

///|
let op : @sdk.GuestOperator = @sdk.GuestOperator::{
  name: "filter",
  process: fn(records) {
    let out : Array[@protocol.Record] = []
    for r in records {
      if keeps(@utf8.decode_lossy(r.value[0:r.value.length()])) {
        out.push(r)
      }
    }
    Ok(out)
  },
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(op, input)
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
