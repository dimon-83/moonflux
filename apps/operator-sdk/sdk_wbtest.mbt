// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for apps/operator-sdk — guest behaviors and the
// buffered-call protocol (the same slots the wasm ABI exports use).

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 3L,
    key: b"",
    value: @utf8.encode(value[0:value.length()]),
    headers: [],
  }
}

///|
fn value_of(r : @protocol.Record) -> String {
  @utf8.decode_lossy(r.value[0:r.value.length()])
}

///|
test "identity behavior round trips through the envelope" {
  let input = [rec("a"), rec("b")]
  match run_call(identity(), encode_output(input)) {
    Ok(output) => match decode_input(output) {
      Ok(decoded) => assert_eq(decoded, input)
      Err(e) => abort("decode: \{e}")
    }
    Err(e) => abort("run: \{e}")
  }
}

///|
test "buffered call: identity end to end" {
  let input = [rec("x"), rec("y")]
  let payload = encode_output(input)
  // host flow: alloc_input(len) -> write payload into the slot ->
  // process -> output_len. The write is simulated here by assigning
  // the same slot the wasm host fills byte-by-byte.
  let _ = alloc_input(payload.length())
  call_state.input_buf = payload
  match run_buffered(identity(), payload) {
    0 => ()
    status => abort("status \{status}: \{last_error_text()}")
  }
  assert_eq(output_len(), payload.length())
  assert_true(last_error_text() == "")
  // the buffered output decodes back to the input records
  match decode_input(buffered_output()) {
    Ok(decoded) => assert_eq(decoded, input)
    Err(e) => abort("output: \{e}")
  }
}

///|
test "buffered call: uppercase transforms values" {
  let input = [rec("make"), rec("loud")]
  let _ = alloc_input(8)
  call_state.input_buf = encode_output(input)
  match run_buffered(uppercase(), call_state.input_buf) {
    0 => ()
    status => abort("status \{status}: \{last_error_text()}")
  }
  match decode_input(buffered_output()) {
    Ok(decoded) => {
      assert_eq(value_of(decoded[0]), "MAKE")
      assert_eq(value_of(decoded[1]), "LOUD")
    }
    Err(e) => abort("output: \{e}")
  }
}

///|
test "uppercase behavior semantics" {
  let out = match (uppercase().process)([rec("make"), rec("MixEd")]) {
    Ok(out) => out
    Err(e) => abort("process: \{e}")
  }
  assert_eq(out.length(), 2)
  assert_eq(value_of(out[0]), "MAKE")
  assert_eq(value_of(out[1]), "MIXED")
  // timestamps/headers ride along untouched
  assert_eq(out[0].timestamp, 3L)
}

///|
test "config parse accepts objects, rejects the rest" {
  assert_true(parse_config(@utf8.encode("{}"[0:2])) is Ok(_))
  assert_true(
    parse_config(@utf8.encode("{\"k\": 1}"[0:8])) is Ok(_),
  )
  assert_true(parse_config(@utf8.encode("[]"[0:2])) is Err(_))
  assert_true(parse_config(@utf8.encode("nope"[0:4])) is Err(_))
}

///|
test "malformed envelope fails with status and error text" {
  let _ = alloc_input(4)
  // the zeroed slot is not a valid batch frame
  assert_true(run_buffered(identity(), call_state.input_buf) != 0)
  assert_true(last_error_text() != "")
}
