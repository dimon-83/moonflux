// SPDX-License-Identifier: Apache-2.0
// adapters/wasmtime-native/scalar.mbt (P26): the v2 scalar-call path.
//
// One evaluation = one allocation, one call, one read back, with the
// per-call fuel installed immediately before the call — the scalar
// budget is "this evaluation may burn at most N instructions",
// independent of any batch budget. Failure is fail-closed exactly like
// the batch path: a trap that ran out of fuel is a BudgetExceeded, a
// guest-reported error is an EvalError, and nothing partial ever
// reaches the caller.

///|
/// Probes the session for the v2 scalar exports. Returns the guest's
/// scalar ABI version, or None when the module is v1-only (a fact
/// about the module, not an error).
fn scalar_version(session : Session, err : FixedArray[Byte]) -> Int? {
  let out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_scalar_version(session.handle, out, err, err.length()) != 0 {
    return None
  }
  if out[0] <= 0 {
    return None
  }
  Some(out[0])
}

///|
/// The scalar-eval bound: an answer is one value, so the record-size
/// budget bounds it — the same truth everywhere else.
fn scalar_answer_bound() -> Int {
  @protocol.MAX_RECORD_BYTES
}

///|
/// Runs one scalar evaluation against a live session.
fn scalar_eval_call(
  session : Session,
  name : String,
  args : Array[@operator.ScalarValue],
  err : FixedArray[Byte],
) -> Result[@operator.ScalarValue, @operator.OperatorError] {
  let request = @operator.encode_scalar_request(name, args)
  let ptr = match alloc_buffer(session, request.length()) {
    Ok(ptr) => ptr
    Err(e) => return Err(e)
  }
  if we_mem_write(
      session.handle,
      ptr,
      request,
      request.length(),
      err,
      err.length(),
    ) !=
    0 {
    return Err(call_err(err))
  }
  // the scalar budget is per call, independent of the batch budget
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
  let rc = we_scalar_eval(
    session.handle,
    ptr,
    request.length(),
    out,
    err,
    err.length(),
  )
  if rc != 0 {
    if rc == -2 {
      // a trap: fuel exhaustion maps to the structured budget error,
      // everything else is the guest's trap text
      let fuel_out : FixedArray[Int64] = FixedArray::make(1, 0L)
      if we_fuel_left(session.handle, fuel_out, err, err.length()) == 0 &&
        fuel_out[0] <= 0L {
        return Err(
          @operator.BudgetExceeded(
            "scalar evaluation exhausted its fuel budget (\{@operator.fuel_per_call(session.spec.budget)} instructions)",
          ),
        )
      }
    }
    return Err(@operator.GuestTrap(read_err(err)))
  }
  // the answer pointer rides the call's return; length and failure
  // ride v1's existing output_len / last_status exports
  let status_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_last_status(session.handle, status_out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  if status_out[0] != 0 {
    return Err(@operator.EvalError(guest_error_text(session, err)))
  }
  let len_out : FixedArray[Int] = FixedArray::make(1, 0)
  if we_output_len(session.handle, len_out, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  let olen = len_out[0]
  if olen < 0 || olen > scalar_answer_bound() {
    return Err(
      @operator.BadEnvelope("scalar answer length \{olen} out of bounds"),
    )
  }
  let buf : FixedArray[Byte] = FixedArray::make(olen, b'\x00')
  if we_mem_read(session.handle, out[0], buf, olen, err, err.length()) != 0 {
    return Err(call_err(err))
  }
  let answer = Bytes::from_fixedarray(buf, len=olen)
  match @operator.decode_scalar_answer(answer) {
    Ok(v) => Ok(v)
    Err(e) => Err(@operator.BadEnvelope("scalar answer: \{e}"))
  }
}
