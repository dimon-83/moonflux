// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the uppercase operator.

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
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(@sdk.uppercase(), input)
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
