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
priv struct CallState {
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
/// Runs one buffered call over the host-provided input (the pointer
/// the host received from mf_op_alloc_input, passed back here as a
/// guest Bytes). Output lands in the slot; returns the status code
/// (0 = ok).
pub fn run_buffered(op : GuestOperator, input : Bytes) -> Int {
  match run_call(op, input) {
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
pub fn run_call(op : GuestOperator, input : Bytes) -> Result[Bytes, String] {
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
/// Reads a string-valued config key, so operators that only need
/// scalars don't have to import the JSON package themselves.
pub fn config_string(config : Map[String, Json], key : String) -> String? {
  match config.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Reads an integer-valued config key. The core JSON package carries
/// every number as a double, so this is where an operator's
/// `{"min_len": 10}` becomes a typed Int — and the only place a
/// fractional value could be rounded, which is why it is refused
/// instead: a config that says 10.5 must not silently mean 10.
pub fn config_int(config : Map[String, Json], key : String) -> Int? {
  match config.get(key) {
    Some(Number(n)) => {
      let i = n.to_int()
      if i.to_double() == n {
        Some(i)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Identity operator: records pass through unchanged.
pub fn identity() -> GuestOperator {
  GuestOperator::{ name: "identity", process: fn(records) { Ok(records) }, }
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
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value: @utf8.encode(value.to_upper()[0:value.length()]),
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
}

///|
/// Passthrough operator: every record through, unchanged (the batch
/// face of a scalar-focused module).
pub fn passthrough() -> GuestOperator {
  GuestOperator::{ name: "passthrough", process: fn(records) { Ok(records) }, }
}

///|
/// ASCII-scope uppercase, mirroring mbel's upper() exactly — the
/// crosscheck's byte-identity claim covers the same character range.
pub fn uppercase_str(text : String) -> String {
  let sb = StringBuilder::new()
  for ch in text {
    let code = ch.to_int()
    if code >= 97 && code <= 122 {
      sb.write_char((code - 32).unsafe_to_char())
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// ABI entry: the scalar ABI version this SDK implements (drives
/// mf_op_scalar_abi_version).
pub fn scalar_abi_version() -> Int {
  @operator.SCALAR_ABI_VERSION
}

// ---------------------------------------------------------------------------
// ABI v2 scalar calls (P26): a guest may serve named scalar functions
// over `mf_op_eval`. The request arrives as JSON ({"fn":name,"args":[...]}),
// the answer leaves as JSON ({"v":...}); failures ride the same
// last_status/last_error channel the batch path uses, so a failed
// evaluation never returns a partial answer. Parameter kinds are
// DECLARED here and checked explicitly — unlike mbel's call-site
// inference, a sandbox function states what it accepts (the design's
// open question 5).

///|
/// The parameter kinds a scalar function declares.
pub(all) enum ScalarKind {
  KStr
  KNum
  KBool
  KArr
} derive(Debug, Eq)

///|
/// One sandboxed scalar function: its name, its declared parameter
/// kinds, and the pure evaluation itself. No IO, no clock — the guest
/// has no imports, so determinism is structural.
pub(all) struct GuestScalarFn {
  name : String
  params : Array[ScalarKind]
  eval : (Array[@operator.ScalarValue]) -> Result[@operator.ScalarValue, String]
}

///|
fn scalar_kind_ok(kind : ScalarKind, v : @operator.ScalarValue) -> Bool {
  match (kind, v) {
    (KStr, SStr(_)) => true
    (KNum, SNum(_)) => true
    (KBool, SBool(_)) => true
    (KArr, SArr(_)) => true
    (_, _) => false
  }
}

///|
fn scalar_kind_name(kind : ScalarKind) -> String {
  match kind {
    KStr => "string"
    KNum => "number"
    KBool => "bool"
    KArr => "array"
  }
}

///|
/// Runs one scalar evaluation over the host's request bytes. The
/// answer becomes the buffered output (read back through
/// mf_op_output_len, exactly like a batch); a failure sets
/// last_status/last_error and leaves the output empty.
pub fn run_scalar(fns : Array[GuestScalarFn], payload : Bytes) -> Bytes {
  match run_scalar_inner(fns, payload) {
    Ok(answer) => {
      call_state.output_buf = answer
      call_state.last_status = 0
      call_state.output_buf
    }
    Err(e) => {
      call_state.output_buf = b""
      call_state.last_status = 1
      call_state.last_error = e
      b""
    }
  }
}

///|
fn run_scalar_inner(
  fns : Array[GuestScalarFn],
  payload : Bytes,
) -> Result[Bytes, String] {
  let (name, args) = match @operator.decode_scalar_request(payload) {
    Ok(parsed) => parsed
    Err(e) => return Err("request: \{e}")
  }
  let mut found : GuestScalarFn? = None
  for f in fns {
    if f.name == name {
      found = Some(f)
    }
  }
  let f = match found {
    Some(f) => f
    None => return Err("no scalar function '\{name}'")
  }
  if f.params.length() != args.length() {
    return Err(
      "\{name} expects \{f.params.length()} argument(s), got \{args.length()}",
    )
  }
  for i = 0; i < f.params.length(); i = i + 1 {
    if !scalar_kind_ok(f.params[i], args[i]) {
      return Err(
        "\{name}'s argument \{i} must be \{scalar_kind_name(f.params[i])}",
      )
    }
  }
  let value = match (f.eval)(args) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok(@operator.encode_scalar_answer(value))
}
