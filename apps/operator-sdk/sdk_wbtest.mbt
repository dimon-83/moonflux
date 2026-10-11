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
    Ok(output) =>
      match decode_input(output) {
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
  assert_true(parse_config(@utf8.encode("{\"k\": 1}"[0:8])) is Ok(_))
  assert_true(parse_config(@utf8.encode("[]"[0:2])) is Err(_))
  assert_true(parse_config(@utf8.encode("nope"[0:4])) is Err(_))
}

///|
test "config_int types a JSON number and refuses a fractional one" {
  let text = "{\"min_len\": 10, \"ratio\": 0.5, \"name\": \"x\"}"
  let cfg = match parse_config(@utf8.encode(text[0:text.length()])) {
    Ok(cfg) => cfg
    Err(e) => abort("config rejected: \{e}")
  }
  // an integer survives the double round trip
  assert_eq(config_int(cfg, "min_len"), Some(10))
  // a fractional value is refused rather than truncated: a config that
  // says 10.5 must not silently mean 10
  assert_eq(config_int(cfg, "ratio"), None)
  // a missing key and a non-numeric one are both None, not 0
  assert_eq(config_int(cfg, "absent"), None)
  assert_eq(config_int(cfg, "name"), None)
  // the string reader is unaffected
  assert_eq(config_string(cfg, "name"), Some("x"))
}

///|
test "malformed envelope fails with status and error text" {
  let _ = alloc_input(4)
  // the zeroed slot is not a valid batch frame
  assert_true(run_buffered(identity(), call_state.input_buf) != 0)
  assert_true(last_error_text() != "")
}

///|
test "a stateful call receives state and returns the state to write back" {
  // the smallest thing that proves state crosses the boundary: it appends
  // this batch's values to whatever the state said, and hands the result
  // back as the state to keep
  let appender = GuestStatefulOperator::{
    name: "appender",
    process: fn(state, records) {
      let mut acc = ""
      for e in state {
        if @utf8.decode_lossy(e.key[0:e.key.length()]) == "log" {
          acc = @utf8.decode_lossy(e.value[0:e.value.length()])
        }
      }
      for r in records {
        acc = acc + value_of(r)
      }
      let out : Array[@operator.StateEntry] = [
        @operator.StateEntry::{
          key: @utf8.encode("log"),
          value: @utf8.encode(acc),
        },
      ]
      Ok((out, records))
    },
  }
  // first batch: no prior state
  assert_eq(
    run_stateful(
      appender,
      @operator.encode_state_payload([], [rec("a"), rec("b")]),
    ),
    0,
  )
  let (state1, records1) = match
    @operator.decode_state_payload(buffered_output()) {
    Ok(pair) => pair
    Err(e) => abort("decode: \{e}")
  }
  assert_eq(state1.length(), 1)
  assert_eq(
    @utf8.decode_lossy(state1[0].value[0:state1[0].value.length()]),
    "ab",
  )
  assert_eq(records1.length(), 2)
  // second batch: the host feeds the state it got back, so the guest sees
  // what the previous call wrote
  assert_eq(
    run_stateful(appender, @operator.encode_state_payload(state1, [rec("c")])),
    0,
  )
  let (state2, _) = match @operator.decode_state_payload(buffered_output()) {
    Ok(pair) => pair
    Err(e) => abort("decode: \{e}")
  }
  assert_eq(
    @utf8.decode_lossy(state2[0].value[0:state2[0].value.length()]),
    "abc",
  )
}

///|
test "a stateful call that refuses is fail-closed" {
  let refusing = GuestStatefulOperator::{
    name: "refuser",
    process: fn(_state, _records) { Err("nope") },
  }
  let input = @operator.encode_state_payload([], [rec("a")])
  assert_eq(run_stateful(refusing, input), 1)
  assert_eq(buffered_output().length(), 0)
  assert_true(last_error_text().contains("nope"))
}

///|
test "a malformed state payload is refused before the guest runs" {
  let never = GuestStatefulOperator::{
    name: "never",
    process: fn(_state, _records) {
      abort("the guest must not run on a malformed payload")
    },
  }
  let input = b"\x05\x01k"
  assert_eq(run_stateful(never, input), 1)
  assert_true(last_error_text().contains("state payload"))
}
