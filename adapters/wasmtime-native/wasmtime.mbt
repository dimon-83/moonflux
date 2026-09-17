// SPDX-License-Identifier: Apache-2.0
// adapters/wasmtime-native: implements core/operator's injected
// OperatorEngine interface on top of the wasmtime C API shim.
//
// Call flow per batch (buffered ABI, guest-owned slots):
//   alloc_input(len) -> write payload into linear memory at the
//   returned data pointer -> process(ptr) -> output_len() -> read the
//   output bytes from the returned pointer -> decode the envelope.
//
// Timeout enforcement (tier hints) lands with the concurrency
// milestone; the record-count budget is enforced here today.

///|
fn read_err(err : FixedArray[Byte]) -> String {
  // the shim NUL-terminates; scan up to the terminator
  let sb = StringBuilder::new()
  for i in 0..<err.length() {
    let b = err[i]
    if b == b'\x00' {
      break
    }
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn call_err(err : FixedArray[Byte]) -> @operator.OperatorError {
  @operator.GuestTrap(read_err(err))
}

///|
priv struct Session {
  handle : Int64
  spec : @operator.OperatorSpec
}

///|
/// Builds the real wasm operator engine. `load_module` reads the
/// compiled .wasm artifact (callers pass the loader so the adapter
/// stays decoupled from any one file-system helper).
pub fn operator_engine(
  load_module : (String) -> Result[Bytes, String],
) -> @operator.OperatorEngine {
  @operator.OperatorEngine::{
    instantiate: fn(spec) {
      match spec.validate() {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      let wasm = match load_module(spec.module_path) {
        Ok(wasm) => wasm
        Err(e) =>
          return Err(@operator.InvalidSpec("load \{spec.module_path}: \{e}"))
      }
      let err : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
      let handle = we_session_new(wasm, wasm.length(), err, err.length())
      if handle == 0L {
        return Err(@operator.InvalidSpec(read_err(err)))
      }
      let session = Session::{ handle, spec }
      // ABI version handshake
      let out : FixedArray[Int] = FixedArray::make(1, 0)
      if we_abi_version(session.handle, out, err, err.length()) != 0 {
        we_session_free(session.handle)
        return Err(@operator.GuestTrap("abi_version: " + read_err(err)))
      }
      match @operator.validate_abi_version(out[0]) {
        Err(e) => {
          we_session_free(session.handle)
          return Err(e)
        }
        Ok(_) => ()
      }
      // init with the spec's config payload (guest-defined JSON)
      let config = session.spec.config
      let cfg_bytes = @utf8.encode(config)
      let empty = alloc_buffer(session, cfg_bytes.length())
      match empty {
        Err(e) => {
          we_session_free(session.handle)
          return Err(e)
        }
        Ok(ptr) => {
          if we_mem_write(
              session.handle,
              ptr,
              cfg_bytes,
              cfg_bytes.length(),
              err,
              err.length(),
            ) !=
            0 {
            we_session_free(session.handle)
            return Err(call_err(err))
          }
          let init_out : FixedArray[Int] = FixedArray::make(1, 0)
          if we_init(session.handle, ptr, init_out, err, err.length()) != 0 {
            we_session_free(session.handle)
            return Err(@operator.GuestTrap("init: " + read_err(err)))
          }
          if init_out[0] != 0 {
            we_session_free(session.handle)
            return Err(
              @operator.InvalidSpec("operator rejected its config: \{config}"),
            )
          }
        }
      }
      // The wall clock lives here, in the adapter, and it is used for
      // *reporting* only: the enforceable budget is fuel, because fuel
      // is reproducible and a clock is not (README 决策 33).
      let last_ms : Array[Int?] = [None]
      Ok(@operator.OperatorInstance::{
        abi_version: out[0],
        process: fn(records) {
          let started = @env.now().reinterpret_as_int64()
          let result = process_batch(session, records)
          let elapsed = @env.now().reinterpret_as_int64() - started
          last_ms[0] = Some((if elapsed < 0L { 0L } else { elapsed }).to_int())
          result
        },
        last_call_ms: fn() { last_ms[0] },
        close: fn() { we_session_free(session.handle) },
      })
    },
  }
}

///|
/// Allocates a guest buffer and returns its data pointer.
fn alloc_buffer(
  session : Session,
  len : Int,
) -> Result[Int, @operator.OperatorError] {
  let err : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
  let out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_alloc_input(session.handle, len, out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  Ok(out[0])
}

///|
fn process_batch(
  session : Session,
  records : Array[@protocol.Record],
) -> Result[Array[@protocol.Record], @operator.OperatorError] {
  match @operator.check_budget(session.spec.budget, records.length()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let payload = @operator.encode_process_payload(records)
  let err : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
  // 1. hand the payload to the guest buffer
  let ptr = match alloc_buffer(session, payload.length()) {
    Ok(ptr) => ptr
    Err(e) => return Err(e)
  }
  if we_mem_write(
      session.handle,
      ptr,
      payload,
      payload.length(),
      err,
      err.length(),
    ) !=
    0 {
    return Err(call_err(err))
  }
  // 2. install the tier's instruction budget, then run the operator
  // over the buffer. Fuel is a deterministic meter: a guest that runs
  // away hits it and we report a budget error, never a generic trap.
  let fuel_out : FixedArray[Int64] = FixedArray::make(1, 0L)
  if we_set_fuel(
      session.handle,
      @operator.fuel_per_call(session.spec.budget),
      err,
      err.length(),
    ) !=
    0 {
    return Err(call_err(err))
  }
  let out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_process(session.handle, ptr, out, err, err.length()) != 0 {
    if we_fuel_left(session.handle, fuel_out, err, err.length()) == 0 &&
      fuel_out[0] <= 0L {
      return Err(
        @operator.BudgetExceeded(
          "operator exhausted its fuel budget (\{@operator.fuel_per_call(session.spec.budget)} instructions) before returning",
        ),
      )
    }
    return Err(call_err(err))
  }
  let out_ptr = out[0]
  // 3. status gate: non-zero means the guest refused the batch
  let status_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_last_status(session.handle, status_out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  if status_out[0] != 0 {
    return Err(@operator.GuestTrap(guest_error_text(session, err)))
  }
  // 4. read the buffered output length, then the bytes
  let len_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_output_len(session.handle, len_out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  let out_len = len_out[0]
  if out_len < 0 || out_len > @protocol.MAX_BATCH_BYTES {
    return Err(@operator.BadEnvelope("output length \{out_len} out of bounds"))
  }
  let buf : FixedArray[Byte] = FixedArray::make(out_len, b'\x00')
  if we_mem_read(session.handle, out_ptr, buf, out_len, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  let output = Bytes::from_fixedarray(buf, len=out_len)
  match @operator.decode_process_payload(output) {
    Ok(records) => Ok(records)
    Err(e) => Err(e)
  }
}

///|
/// Reads the guest's last-error text. mf_op_last_error returns the
/// data pointer of a guest byte object; its length lives in the
/// header at ptr-4 (moonc boxed-array layout, see the spike doc).
fn guest_error_text(session : Session, err : FixedArray[Byte]) -> String {
  let err2 : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
  let ptr_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_last_error(session.handle, ptr_out, err2, err2.length()) != 0 {
    return read_err(err)
  }
  let len_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_boxed_len(session.handle, ptr_out[0], len_out, err2, err2.length()) != 0 {
    return read_err(err)
  }
  let len = len_out[0]
  if len <= 0 || len > 65536 {
    return read_err(err)
  }
  let buf : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  if we_mem_read(session.handle, ptr_out[0], buf, len, err2, err2.length()) != 0 {
    return read_err(err)
  }
  let sb = StringBuilder::new()
  for i in 0..<len {
    let b = buf[i]
    if b == b'\x00' {
      break
    }
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}
