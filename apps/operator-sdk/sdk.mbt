// SPDX-License-Identifier: Apache-2.0
// apps/operator-sdk: guest-side library for operator authors (P2).
// Guests are `--target wasm` main-style packages exporting the ABI v1
// functions; this library carries the envelope codec, the init-config
// parse, and the behavioral contract so an operator only implements
// one pure function: records in, records out.
//
// Imports live in moon.pkg. Kernel packages only (guests inherit the
// kernel red lines: no IO inside the sandbox).

///|
/// The behavioral contract an operator implements. Positional: the
/// host reattaches offsets; guests never see them.
pub(all) struct GuestOperator {
  name : String
  process : (Array[@protocol.Record]) -> Result[Array[@protocol.Record], String]
}

///|
/// ABI entry: the version this SDK implements (drives mf_op_abi_version).
pub fn abi_version() -> Int {
  @operator.ABI_VERSION
}

///|
/// Envelope decode for mf_op_process input.
pub fn decode_input(payload : Bytes) -> Result[Array[@protocol.Record], String] {
  match @operator.decode_process_payload(payload) {
    Ok(records) => Ok(records)
    Err(e) => Err("\{e}")
  }
}

///|
/// Envelope encode for mf_op_process output.
pub fn encode_output(records : Array[@protocol.Record]) -> Bytes {
  @operator.encode_process_payload(records)
}

///|
/// Buffered-call protocol state. The host cannot fabricate a guest
/// Bytes (boxed pointer with header), so the guest owns allocation:
/// mf_op_alloc_input returns the data pointer of a guest-held buffer
/// (the call-state global keeps refcounts alive), the host writes
/// bytes there, and mf_op_process receives the same pointer back as
/// a real Bytes. Output flows the same way; its length is exposed
/// separately because the host must not parse MoonBit object headers.
struct CallState {
  mut input_buf : Bytes
  mut output_buf : Bytes
  mut last_status : Int
  mut last_error : String
}

///|
let call_state : CallState = CallState::{
  input_buf: b"",
  output_buf: b"",
  last_status: 0,
  last_error: "",
}

///|
/// Allocates the input buffer of `len` bytes; the host writes the
/// payload into linear memory at the returned data pointer. The
/// buffer stays alive in the call-state global until the next
/// allocation.
pub fn alloc_input(len : Int) -> Bytes {
  call_state.input_buf = Bytes::make(len, b'\x00')
  call_state.input_buf
}

///|
/// Runs one buffered call: decode -> apply -> encode -> output slot.
/// Returns the status code (0 = ok).
pub fn run_buffered(op : GuestOperator) -> Int {
  match run_call(op, call_state.input_buf) {
    Ok(output) => {
      call_state.output_buf = output
      call_state.last_status = 0
    }
    Err(e) => {
      call_state.output_buf = b""
      call_state.last_status = 1
      // the error text is host-visible via last_error_text
      call_state.last_error = e
    }
  }
  call_state.last_status
}

///|
/// The buffered output (the host reads its bytes through the pointer
/// that mf_op_process returned).
pub fn buffered_output() -> Bytes {
  call_state.output_buf
}

///|
/// The length of the buffered output (host reads the bytes from the
/// pointer that mf_op_process returned).
pub fn output_len() -> Int {
  call_state.output_buf.length()
}

///|
/// The status of the last buffered call (0 = ok).
pub fn last_status() -> Int {
  call_state.last_status
}

///|
/// The last error as guest bytes (utf-8).
pub fn last_error_bytes() -> Bytes {
  @utf8.encode(call_state.last_error[0:call_state.last_error.length()])
}

///|
/// The error text of the last failed call (empty when status 0).
pub fn last_error_text() -> String {
  call_state.last_error
}

///|
/// Runs a guest operator over one process-call payload: decode ->
/// apply -> encode. The ABI function bodies in each operator package
/// are three lines around this.
pub fn run_call(
  op : GuestOperator,
  input : Bytes,
) -> Result[Bytes, String] {
  let records = match decode_input(input) {
    Ok(records) => records
    Err(e) => return Err(e)
  }
  let out = match (op.process)(records) {
    Ok(out) => out
    Err(e) => return Err("operator \{op.name}: \{e}")
  }
  Ok(encode_output(out))
}

///|
/// Parses the init-config JSON payload (UTF-8 object). Operators that
/// need no config still accept `{}`.
pub fn parse_config(config : Bytes) -> Result[Map[String, Json], String] {
  let text = @utf8.decode_lossy(config[0:config.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("config is not valid JSON: \{e}")
  }
  match json {
    Object(map) => Ok(map)
    _ => Err("config must be a JSON object")
  }
}

///|
/// Identity operator: records pass through unchanged.
pub fn identity() -> GuestOperator {
  GuestOperator::{
    name: "identity",
    process: fn(records) {
      Ok(records)
    },
  }
}

///|
/// Uppercase operator: ASCII-uppercase every record value (semantics
/// anchor for the P2 crosscheck; mirrors mbel's upper() ASCII scope).
pub fn uppercase() -> GuestOperator {
  GuestOperator::{
    name: "uppercase",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let value = @utf8.decode_lossy(r.value[0:r.value.length()])
        out.push(
          @protocol.Record::{
            timestamp: r.timestamp,
            key: r.key,
            value: @utf8.encode(value.to_upper()[0:value.length()]),
            headers: r.headers,
          },
        )
      }
      Ok(out)
    },
  }
}
