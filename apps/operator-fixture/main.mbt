// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the sandbox fixture operator.
//
// The behavior is chosen by the init config so one module can cover
// every failure path the host must handle:
//   {}                    identity (baseline)
//   {"mode": "refuse"}    return a non-zero status plus an error text
//   {"mode": "trap"}      trap inside mf_op_process
//   {"mode": "spin"}      run away until the host's fuel budget stops it

///|
/// Guest-side state: the mode selected at init. Top-level mutable
/// fields must live in a struct (MoonBit has no top-level `let mut`).
priv struct FixtureState {
  mut mode : String
}

///|
let state : FixtureState = FixtureState::{ mode: "identity", }

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
}

///|
pub fn mf_op_init(config : Bytes) -> Int {
  match @sdk.parse_config(config) {
    Ok(cfg) =>
      match @sdk.config_string(cfg, "mode") {
        Some(m) =>
          match m {
            "identity" | "refuse" | "trap" | "spin" => {
              state.mode = m
              0
            }
            _ => -1
          }
        None => {
          state.mode = "identity"
          0
        }
      }
    Err(_) => -1
  }
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  match state.mode {
    "refuse" => {
      // a governed refusal: status 1 plus a host-visible reason
      let _ = @sdk.run_buffered(
        @sdk.GuestOperator::{
          name: "fixture-refuse",
          process: fn(_records) { Err("fixture refused this batch on purpose") },
        },
        input,
      )
      @sdk.buffered_output()
    }
    "trap" =>
      // an uncontrolled guest failure: no status, just a wasm trap
      abort("fixture: deliberate trap")
    "spin" => {
      // a runaway operator: never returns, must be stopped by the
      // host's deterministic fuel budget (no clock involved)
      let mut i = 0
      while true {
        i = (i + 1) % 1000000
        if i < 0 {
          break
        }
      }
      b""
    }
    _ => {
      let _ = @sdk.run_buffered(@sdk.identity(), input)
      @sdk.buffered_output()
    }
  }
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
