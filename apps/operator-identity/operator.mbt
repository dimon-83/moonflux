// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the identity operator. The host calls these
// exports; all behavior lives in apps/operator-sdk.
//
// Buffered-call protocol (guest-owned allocation, see sdk.mbt):
//   1. host: len = expected payload size; ptr = mf_op_alloc_input(len)
//   2. host: write payload bytes at [ptr, ptr+len) via exported memory
//   3. host: status = mf_op_process(input)   (input = ptr as a Bytes)
//   4. host: read output at the returned pointer, length = mf_op_output_len()

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
    Ok(_) => 0
    Err(_) => -1
  }
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(@sdk.identity())
  // the host reads the buffered output through the returned pointer
  // (same slot the sdk wrote); status/length come from their exports
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
/// WASI command entry (unused by the host path; satisfies the linker).
fn main {
  let _ = mf_op_abi_version()
}
