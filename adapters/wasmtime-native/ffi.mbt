// SPDX-License-Identifier: Apache-2.0
// adapters/wasmtime-native: operator host via the wasmtime C API.
// One opaque session handle (Int64) per instantiated module; the
// MoonBit side is a thin, structured facade over the shim.

///|
#borrow(wasm, err)
pub extern "C" fn we_session_new(wasm : Bytes, len : Int, err : FixedArray[Byte], err_len : Int) -> Int64 = "mf_we_session_new"

///|
pub extern "C" fn we_session_free(session : Int64) -> Unit = "mf_we_session_free"

///|
#borrow(out, err)
pub extern "C" fn we_abi_version(session : Int64, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_abi_version"

///|
#borrow(out, err)
pub extern "C" fn we_alloc_input(session : Int64, len : Int, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_alloc_input"

///|
#borrow(out, err)
pub extern "C" fn we_init(session : Int64, config_ptr : Int, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_init"

///|
#borrow(out, err)
pub extern "C" fn we_process(session : Int64, input_ptr : Int, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_process"

///|
#borrow(out, err)
pub extern "C" fn we_output_len(session : Int64, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_output_len"

///|
#borrow(out, err)
pub extern "C" fn we_last_status(session : Int64, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_last_status"

///|
#borrow(data, err)
pub extern "C" fn we_mem_write(session : Int64, ptr : Int, data : Bytes, len : Int, err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_mem_write"

///|
#borrow(out, err)
pub extern "C" fn we_mem_read(session : Int64, ptr : Int, out : FixedArray[Byte], len : Int, err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_mem_read"

///|
#borrow(out, err)
pub extern "C" fn we_boxed_len(session : Int64, ptr : Int, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_boxed_len"

///|
#borrow(out, err)
pub extern "C" fn we_last_error(session : Int64, out : FixedArray[Int], err : FixedArray[Byte], err_len : Int) -> Int = "mf_we_last_error"
