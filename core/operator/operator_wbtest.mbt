// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/operator — ABI envelope, budget policy,
// and the injected-engine contract.

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 1L,
    key: b"",
    value: @utf8.encode(value[0:value.length()]),
    headers: [],
  }
}

///|
fn spec(budget : BudgetTier) -> OperatorSpec {
  OperatorSpec::{ name: "op", module_path: "operators/identity.wasm", budget }
}

///|
test "envelope round trip carries records, never offsets" {
  let records = [rec("a"), rec("b"), rec("c")]
  let payload = encode_process_payload(records)
  match decode_process_payload(payload) {
    Ok(decoded) => assert_eq(decoded, records)
    Err(e) => abort("decode: \{e}")
  }
  // the envelope always marks offsets unassigned: the guest must not
  // see host bookkeeping
  match @protocol.decode_frame_strict(payload) {
    Ok(batch) => assert_eq(batch.base_offset, ENVELOPE_BASE_OFFSET)
    Err(e) => abort("frame: \{e}")
  }
}

///|
test "envelope rejects foreign frames" {
  // a frame with a real base offset is not a valid envelope
  let frame = @protocol.encode_frame(7L, [rec("x")])
  assert_true(decode_process_payload(frame) is Err(_))
  // garbage is a structured error, not a panic
  assert_true(decode_process_payload(b"garbage") is Err(_))
}

///|
test "abi version validation" {
  assert_true(validate_abi_version(ABI_VERSION) is Ok(_))
  assert_eq(validate_abi_version(2), Err(AbiVersionMismatch(2)))
  assert_eq(validate_abi_version(0), Err(AbiVersionMismatch(0)))
}

///|
test "budget tiers cap record counts" {
  assert_eq(max_records_per_call(Internal), 100000)
  assert_eq(max_records_per_call(User), 10000)
  assert_eq(max_records_per_call(Tenant), 1000)
  assert_true(check_budget(User, 10000) is Ok(_))
  assert_true(check_budget(User, 10001) is Err(BudgetExceeded(_)))
  // timeout hints scale the same direction
  assert_true(call_timeout_hint_ms(Internal) > call_timeout_hint_ms(Tenant))
}

///|
test "passthrough engine round trips through the envelope" {
  let engine = passthrough_engine()
  let instance = match (engine.instantiate)(spec(Internal)) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  assert_eq(instance.abi_version, ABI_VERSION)
  let records = [rec("hello"), rec("world")]
  match (instance.process)(records) {
    Ok(out) => assert_eq(out, records)
    Err(e) => abort("process: \{e}")
  }
  (instance.close)()
}

///|
test "engines enforce spec validation and budget" {
  let engine = passthrough_engine()
  // invalid spec refused at instantiate
  let bad = OperatorSpec::{ name: "", module_path: "x.wasm", budget: Internal }
  assert_true((engine.instantiate)(bad) is Err(_))
  // budget enforced inside process
  let engine2 = fn_engine(fn(records) { records })
  let instance = match (engine2.instantiate)(spec(Tenant)) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  let big : Array[@protocol.Record] = []
  for _i in 0..<1001 {
    big.push(rec("x"))
  }
  assert_true((instance.process)(big) is Err(_))
}

///|
test "fn engine applies the native transform (crosscheck baseline)" {
  let upper = fn_engine(fn(records) {
    let out : Array[@protocol.Record] = []
    for r in records {
      let value = @utf8.decode_lossy(r.value[0:r.value.length()])
      out.push(@protocol.Record::{
        timestamp: r.timestamp,
        key: r.key,
        value: @utf8.encode(value.to_upper()),
        headers: r.headers,
      })
    }
    out
  })
  let instance = match (upper.instantiate)(spec(Internal)) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  match (instance.process)([rec("make"), rec("me"), rec("loud")]) {
    Ok(out) => {
      assert_eq(out.length(), 3)
      assert_eq(
        @utf8.decode_lossy(out[0].value[0:out[0].value.length()]),
        "MAKE",
      )
    }
    Err(e) => abort("process: \{e}")
  }
}
