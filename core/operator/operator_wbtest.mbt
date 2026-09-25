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
  OperatorSpec::{
    name: "op",
    module_path: "operators/identity.wasm",
    budget,
    config: "{}",
  }
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
test "fuel budgets scale with the tier and stay positive" {
  assert_eq(fuel_per_call(Internal), 50000000L)
  assert_eq(fuel_per_call(User), 10000000L)
  assert_eq(fuel_per_call(Tenant), 2000000L)
  assert_true(fuel_per_call(Internal) > fuel_per_call(User))
  assert_true(fuel_per_call(User) > fuel_per_call(Tenant))
  assert_true(fuel_per_call(Tenant) > 0L)
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
  let bad = OperatorSpec::{
    name: "",
    module_path: "x.wasm",
    budget: Internal,
    config: "{}",
  }
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

///|
test "the wall-clock hint reports, it does not enforce" {
  // the hint is monotone across tiers (tighter trust, tighter number)
  assert_true(call_timeout_hint_ms(Internal) > call_timeout_hint_ms(User))
  assert_true(call_timeout_hint_ms(User) > call_timeout_hint_ms(Tenant))
  // and it is a threshold: exactly at the hint is fine, one over is a
  // report. Nothing here can stop a call that already returned — that
  // is the point (a clock cannot be a replayable budget).
  let hint = call_timeout_hint_ms(Tenant)
  assert_true(!over_time_hint(Tenant, hint))
  assert_true(over_time_hint(Tenant, hint + 1))
  assert_true(!over_time_hint(Internal, hint))
  // fuel is the enforceable one, and it is the same number every time
  assert_eq(fuel_per_call(Tenant), fuel_per_call(Tenant))
  assert_true(fuel_per_call(Internal) > fuel_per_call(Tenant))
}

///|
test "scalar request/answer round trip with the declared kind boundary" {
  let request = encode_scalar_request("tax", [SNum(12.5), SNum(0.2)])
  let (name, args) = match decode_scalar_request(request) {
    Ok(parsed) => parsed
    Err(e) => abort("decode: \{e}")
  }
  assert_eq(name, "tax")
  assert_eq(args.length(), 2)
  assert_true(args[0] is SNum(_))
  // every scalar kind round-trips
  let answer = encode_scalar_answer(
    SArr([SStr("mixed"), SNum(1.5), SBool(true)]),
  )
  match decode_scalar_answer(answer) {
    Ok(SArr(items)) => {
      assert_eq(items.length(), 3)
      assert_true(items[0] is SStr(_))
      assert_true(items[2] is SBool(_))
    }
    Ok(_) => abort("the answer lost its array shape")
    Err(e) => abort("decode answer: \{e}")
  }
  // objects are refused, not smuggled (the design's mapping boundary)
  match decode_scalar_request(@utf8.encode("{\"fn\":\"x\",\"args\":[{}]}")) {
    Err(e) => assert_true(e.contains("object"))
    Ok(_) => abort("an object argument was accepted")
  }
  // a request without a name is refused
  match decode_scalar_request(@utf8.encode("{\"args\":[]}")) {
    Err(e) => assert_true(e.contains("fn"))
    Ok(_) => abort("a nameless request was accepted")
  }
}
