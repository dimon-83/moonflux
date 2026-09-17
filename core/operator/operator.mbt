// SPDX-License-Identifier: Apache-2.0
// core/operator: operator sandbox ABI v1 — the kernel side of the
// wasm operator contract (P2). Pure computation (kernel red lines):
// the wasm runtime lives in adapters; the kernel owns the ABI
// constants, the call envelope, budget policy, and the injected
// engine interface.
//
// ABI v1 (guest module exports, all names fixed here):
//   mf_op_abi_version() -> Int            the ABI this guest targets
//   mf_op_init(config : Bytes) -> Int     0 = ok (JSON config payload)
//   mf_op_process(input : Bytes) -> Bytes one batch in, one batch out
// Bytes crosses the wasm export boundary as (ptr, len) i32 pairs
// (proven by docs/p2-wasm-host-spike.md). Payloads are wire-protocol
// RecordBatch frames with base_offset = -1: offsets belong to the
// host, the guest only reshapes records positionally.

///|
/// The ABI version this kernel speaks. Guests reporting anything else
/// are rejected at instantiate time.
pub const ABI_VERSION = 1

///|
pub const EXPORT_ABI_VERSION = "mf_op_abi_version"

///|
pub const EXPORT_INIT = "mf_op_init"

///|
pub const EXPORT_PROCESS = "mf_op_process"

///|
/// Process-call payloads travel as batch frames with this base
/// offset (offsets never enter the sandbox).
pub const ENVELOPE_BASE_OFFSET : Int64 = -1L

// Budget tiers (report 5.5 grading; P1 experience carried over).
// Enforcement is record count (kernel) + fuel (host, deterministic).
// The wall-clock number is an observation threshold, not a gate:
// see `call_timeout_hint_ms` for why (README 决策 33).

///|
pub(all) enum BudgetTier {
  /// Platform-internal rules: the widest envelope.
  Internal
  /// User-authored rules.
  User
  /// Per-tenant rules: the tightest envelope.
  Tenant
} derive(Debug, Eq, Show)

///|
/// Max records per process call, by tier.
pub fn max_records_per_call(tier : BudgetTier) -> Int {
  match tier {
    Internal => 100000
    User => 10000
    Tenant => 1000
  }
}

///|
/// The wall clock is a *reporting* threshold, never an enforcement one
/// (README 决策 33). Two reasons, and the second is the one that
/// settles it:
///
///   * enforcement belongs to fuel, which is deterministic: the same
///     batch fails the same way on a loaded machine and an idle one;
///   * a wall-clock gate would make the *same batch* pass or fail
///     depending on machine load, which is exactly what the replay red
///     line (AGENTS §5) forbids. A budget that cannot be replayed is
///     not a budget, it is a coin toss.
///
/// So this number is what an operator's *observation* is compared
/// against (`over_time_hint`), and the adapter measures the call. A
/// call that exceeds it is reported, not killed.
pub fn call_timeout_hint_ms(tier : BudgetTier) -> Int {
  match tier {
    Internal => 1000
    User => 500
    Tenant => 200
  }
}

///|
/// Whether a call that took `elapsed_ms` should be *reported* as over
/// its tier's hint. The honest shape of the wall-clock rule: it decides
/// what to say, not what to do — the call has already returned its
/// result by the time anyone can ask.
pub fn over_time_hint(tier : BudgetTier, elapsed_ms : Int) -> Bool {
  elapsed_ms > call_timeout_hint_ms(tier)
}

///|
/// Instruction budget for one process call, by tier. Runtimes with a
/// deterministic fuel meter (wasmtime) install this before each call;
/// exhaustion is a BudgetExceeded, not a trap. Fuel — unlike a clock —
/// is reproducible, so a replayed batch fails the same way.
pub fn fuel_per_call(tier : BudgetTier) -> Int64 {
  match tier {
    Internal => 50000000L
    User => 10000000L
    Tenant => 2000000L
  }
}

///|
/// Operator sandbox failure modes. Closed set: adapters map their
/// platform errors onto these (AGENTS §5).
pub(all) suberror OperatorError {
  /// The spec or payload was rejected before execution.
  InvalidSpec(String)
  /// The guest reported an ABI version this host does not speak.
  AbiVersionMismatch(Int)
  /// The call exceeded its tier's record count (host-side wall-clock
  /// overruns are also reported here by the adapter).
  BudgetExceeded(String)
  /// The guest trapped or returned a malformed envelope.
  GuestTrap(String)
  /// A payload did not decode as a batch frame.
  BadEnvelope(String)
} derive(Debug, Eq)

///|
pub impl Show for OperatorError with fn output(self, logger) {
  match self {
    InvalidSpec(msg) => logger.write_string("InvalidSpec(\{msg})")
    AbiVersionMismatch(v) => logger.write_string("AbiVersionMismatch(\{v})")
    BudgetExceeded(msg) => logger.write_string("BudgetExceeded(\{msg})")
    GuestTrap(msg) => logger.write_string("GuestTrap(\{msg})")
    BadEnvelope(msg) => logger.write_string("BadEnvelope(\{msg})")
  }
}

///|
/// One operator declaration inside a pipeline: which module, which
/// budget, and the guest's own config payload. The export names are
/// fixed by ABI v1 (not configurable); the config is opaque to the
/// kernel and handed to mf_op_init verbatim.
pub(all) struct OperatorSpec {
  name : String
  module_path : String
  budget : BudgetTier
  /// compact JSON text ("{}" = no config)
  config : String
} derive(Debug, Eq, Show)

///|
/// Validates an operator spec.
pub fn OperatorSpec::validate(
  self : OperatorSpec,
) -> Result[Unit, OperatorError] {
  if self.name.length() == 0 || self.name.length() > 128 {
    return Err(InvalidSpec("operator name must be 1..128 chars"))
  }
  if self.module_path.length() == 0 {
    return Err(InvalidSpec("module_path must not be empty"))
  }
  Ok(())
}

///|
/// Validates the guest-reported ABI version.
pub fn validate_abi_version(version : Int) -> Result[Unit, OperatorError] {
  if version != ABI_VERSION {
    return Err(AbiVersionMismatch(version))
  }
  Ok(())
}

///|
/// Validates the record count against the tier before a call.
pub fn check_budget(
  tier : BudgetTier,
  record_count : Int,
) -> Result[Unit, OperatorError] {
  let max = max_records_per_call(tier)
  if record_count > max {
    return Err(
      BudgetExceeded("\{record_count} records exceeds tier cap \{max}"),
    )
  }
  Ok(())
}

///|
/// Encodes the process-call envelope: one batch frame, unassigned
/// base offset. Both directions use this shape.
pub fn encode_process_payload(records : Array[@protocol.Record]) -> Bytes {
  @protocol.encode_frame(ENVELOPE_BASE_OFFSET, records)
}

///|
/// Decodes a process-call envelope.
pub fn decode_process_payload(
  payload : Bytes,
) -> Result[Array[@protocol.Record], OperatorError] {
  match @protocol.decode_frame_strict(payload) {
    Ok(batch) => {
      if batch.base_offset != ENVELOPE_BASE_OFFSET {
        return Err(
          BadEnvelope("envelope must carry the unassigned base offset"),
        )
      }
      Ok(batch.records)
    }
    Err(e) => Err(BadEnvelope("payload is not a batch frame: \{e}"))
  }
}

///|
/// Host-facing engine: injected as function fields (same style as
/// SegmentFile / Conn), so the kernel never touches a wasm runtime.
/// The adapter (adapters/wasmtime-native) supplies the real engine;
/// tests supply in-process engines.
pub(all) struct OperatorEngine {
  /// Instantiates (and ABI-version-checks) one operator module.
  instantiate : (OperatorSpec) -> Result[OperatorInstance, OperatorError]
}

///|
/// A live operator instance: one loaded module, ready for calls.
pub(all) struct OperatorInstance {
  /// The ABI version the guest reported (already validated).
  abi_version : Int
  /// Transforms one batch positionally; offsets are reattached by
  /// the host, the guest never sees them.
  process : (Array[@protocol.Record]) -> Result[
    Array[@protocol.Record],
    OperatorError,
  ]
  /// How long the last process call took, as the **adapter** measured
  /// it (None when the adapter cannot measure — the in-kernel reference
  /// engine has no clock and no need for one). The kernel only reports
  /// this; it never gates on it (README 决策 33).
  last_call_ms : () -> Int?
  close : () -> Unit
}

///|
/// The in-kernel reference engine: passes records through untouched.
/// It pins the envelope round trip and serves as the baseline for
/// the P2 semantic crosscheck (native vs wasm).
pub fn passthrough_engine() -> OperatorEngine {
  OperatorEngine::{
    instantiate: fn(spec) {
      match spec.validate() {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      Ok(OperatorInstance::{
        abi_version: ABI_VERSION,
        process: fn(records) {
          match check_budget(spec.budget, records.length()) {
            Err(e) => return Err(e)
            Ok(_) => ()
          }
          // full envelope round trip: the same bytes a wasm guest
          // would decode and re-encode
          let payload = encode_process_payload(records)
          let decoded = match decode_process_payload(payload) {
            Ok(records) => records
            Err(e) => return Err(e)
          }
          Ok(decoded)
        },
        last_call_ms: fn() { None },
        close: fn() { () },
      })
    },
  }
}

///|
/// Builds an engine from a pure MoonBit function — the "native
/// operator" form. The crosscheck (T17) runs the same transform as
/// both a native fn-engine and a wasm engine and diffs the outputs.
pub fn fn_engine(
  transform : (Array[@protocol.Record]) -> Array[@protocol.Record],
) -> OperatorEngine {
  OperatorEngine::{
    instantiate: fn(spec) {
      match spec.validate() {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      Ok(OperatorInstance::{
        abi_version: ABI_VERSION,
        process: fn(records) {
          match check_budget(spec.budget, records.length()) {
            Err(e) => return Err(e)
            Ok(_) => ()
          }
          Ok(transform(records))
        },
        last_call_ms: fn() { None },
        close: fn() { () },
      })
    },
  }
}
