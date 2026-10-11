// SPDX-License-Identifier: Apache-2.0
// ABI v3 (T114): the stateful call. The shape is deliberately the same as
// the batch path — allocate, write, install fuel, call, then read the
// answer through the shared output_len / last_status / last_error exports
// — because a stateful guest must fail in exactly the same way every other
// guest does. What differs is the entry point and the payload: a state
// prefix in front of the batch frame, decoded here and returned typed so
// the host deals in state entries and records, never in bytes.

///|
/// The state ABI version, or None when the module offers no state exports.
/// The shim answers 1 for "absent" — a fact, not an error — mirroring the
/// scalar probe's contract.
fn state_version(session : Session, err : FixedArray[Byte]) -> Int? {
  let out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_state_version(session.handle, out, err, err.length()) != 0 {
    return None
  }
  if out[0] <= 0 {
    return None
  }
  Some(out[0])
}

///|
/// One stateful call over an already-encoded v3 payload.
fn state_apply_call(
  session : Session,
  payload : Bytes,
  err : FixedArray[Byte],
) -> Result[
  (Array[@operator.StateEntry], Array[@protocol.Record]),
  @operator.OperatorError,
] {
  // the record budget is a property of the batch inside the payload, so
  // the payload is validated before any guest code runs
  let decoded = match @operator.decode_state_payload(payload) {
    Ok(pair) => pair
    Err(e) => return Err(e)
  }
  match @operator.check_budget(session.spec.budget, decoded.1.length()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
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
  // fuel is the enforceable budget (deterministic); the wall clock is the
  // caller's business and is reported elsewhere (README 决策 33)
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
  let rc = we_state_apply(session.handle, ptr, out, err, err.length())
  if rc != 0 {
    if rc == -3 {
      return Err(@operator.InvalidSpec("module has no state exports (ABI v3)"))
    }
    let fuel_out : FixedArray[Int64] = FixedArray::make(1, 0L)
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
  let status_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_last_status(session.handle, status_out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  if status_out[0] != 0 {
    return Err(@operator.GuestTrap(guest_error_text(session, err)))
  }
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
  @operator.decode_state_payload(Bytes::from_fixedarray(buf, len=out_len))
}
