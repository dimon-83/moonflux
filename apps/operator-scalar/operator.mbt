// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface + ABI v2 scalar functions of the fixture module.

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
}

///|
pub fn mf_op_init(config : Bytes) -> Int {
  match @sdk.parse_config(config) {
    Ok(_) => 0
    Err(_) => -1
  }
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
/// The batch face: a passthrough (the module's value for the gate is
/// its scalar face; the batch face exists so v1 and v2 coexist in ONE
/// module, which is the ABI's own claim).
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(@sdk.passthrough(), input)
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

// --- ABI v2 scalar functions (P26) ---------------------------------------

///|
pub fn mf_op_scalar_abi_version() -> Int {
  @sdk.scalar_abi_version()
}

///|
pub fn mf_op_eval(request : Bytes, len : Int) -> Bytes {
  let _ = len // the request's own bytes are authoritative
  @sdk.run_scalar(functions(), request)
}

///|
/// The fixture's two functions, each declaring its parameter kinds:
/// tax multiplies two numbers (the design's own example), shout
/// uppercases a string (byte-comparable against mbel's upper()).
fn functions() -> Array[@sdk.GuestScalarFn] {
  [
    @sdk.GuestScalarFn::{
      name: "tax",
      params: [KNum, KNum],
      eval: fn(args) {
        match (args[0], args[1]) {
          (SNum(a), SNum(b)) => Ok(SNum(a * b))
          (_, _) => Err("unreachable: kinds are checked before eval")
        }
      },
    },
    @sdk.GuestScalarFn::{
      name: "double",
      params: [KNum],
      eval: fn(args) {
        match args[0] {
          SNum(a) => Ok(SNum(a * 2.0))
          _ => Err("unreachable: kinds are checked before eval")
        }
      },
    },
    @sdk.GuestScalarFn::{
      name: "shout",
      params: [KStr],
      eval: fn(args) {
        match args[0] {
          SStr(text) => Ok(SStr(@sdk.uppercase_str(text)))
          _ => Err("unreachable: kinds are checked before eval")
        }
      },
    },
  ]
}

///|
fn main {
  let _ = mf_op_abi_version()
}
