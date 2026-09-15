// apps/transform: mbel-backed dynamic rule execution for records (P1).
// Publish-time static check: expressions compile here, so syntax and
// unknown-function errors are rejected when rules are applied, never
// mid-stream (AGENTS §8). Budget tiering bounds every evaluation.
//
// Engine choice: Vm mode — `Engine::compile` produces an Expression
// whose compiled program is cached and reused for every record
// (hot path: compile once, evaluate per record, report 5.5).

// SPDX-License-Identifier: Apache-2.0

///|
/// Internal budget tier (report 5.5: 内部级). Constants keep the P1
/// surface honest; per-tenant tiers arrive with multi-tenancy (P3+).
pub const BUDGET_MAX_NODES = 10000

///|
pub const BUDGET_MAX_DEPTH = 100

///|
pub const BUDGET_MAX_STEPS = 100000

///|
/// A compiled dynamic rule: ready to evaluate against many records.
pub struct Transform {
  /// The original expression text (rule asset versioning/display).
  source : String
  expr : @mengine.Expression
}

///|
/// Compiles an expression into a reusable transform. Publish-time
/// static check first (AGENTS §8): a strict Compile-mode pass with a
/// probe context rejects syntax errors, unknown functions, unknown
/// variables, and type violations BEFORE any record flows. Runtime
/// then compiles once — the Vm program is cached on the Expression
/// and reused for every record.
pub fn compile(expr : String) -> Result[Transform, String] {
  let engine = @mengine.new()
  engine.set_limits(BUDGET_MAX_NODES, BUDGET_MAX_DEPTH, BUDGET_MAX_STEPS)
  engine.set_engine(@mengine.Vm)
  // strict publish-time check: probe context mirrors the runtime
  // field types (value/key strings, numeric timestamp/headers_count)
  let probe = @ast.ObjectVal([
    ("value", @ast.StrVal("a")),
    ("key", @ast.StrVal("")),
    ("timestamp", @ast.NumVal(1726000000000.0)),
    ("headers_count", @ast.NumVal(0.0)),
  ])
  let _ = engine.eval_expr_checked(expr, probe) catch {
    e => return Err("static check: \{error_text(e)}")
  }
  let compiled = engine.compile(expr) catch {
    e => return Err("compile: \{error_text(e)}")
  }
  Ok(Transform::{ source: expr, expr: compiled })
}

///|
/// Evaluates the rule against one record and returns the transformed
/// record (same key/timestamp/headers, new value). Fail-closed: any
/// evaluation error (unknown variable, budget exceeded, non-string
/// result) surfaces as `Err` — the caller decides skip/reject, the
/// record is never silently mangled.
pub fn apply(
  t : Transform,
  record : @protocol.Record,
) -> Result[@protocol.Record, String] {
  let value = @utf8.decode_lossy(record.value[0:record.value.length()])
  let key = @utf8.decode_lossy(record.key[0:record.key.length()])
  let ctx = @ast.ObjectVal([
    ("value", @ast.StrVal(value)),
    ("key", @ast.StrVal(key)),
    ("timestamp", @ast.NumVal(record.timestamp.to_double())),
    ("headers_count", @ast.NumVal(record.headers.length().to_double())),
  ])
  let out = t.expr.eval(ctx) catch {
    e => return Err("eval: \{error_text(e)}")
  }
  match out {
    @ast.StrVal(new_value) =>
      Ok(@protocol.Record::{
        timestamp: record.timestamp,
        key: record.key,
        value: @utf8.encode(new_value[0:new_value.length()]),
        headers: record.headers,
      })
    other => Err("transform must return a string, got \{value_kind(other)}")
  }
}

///|
/// mbel's EngineError carries its message in the EngineErr variant.
fn error_text(e : @mengine.EngineError) -> String {
  match e {
    EngineErr(msg) => msg
  }
}

///|
fn value_kind(v : @ast.Value) -> String {
  match v {
    BoolVal(_) => "bool"
    NumVal(_) => "number"
    IntVal(_) => "integer"
    BytesVal(_) => "bytes"
    StrVal(_) => "string"
    ArrayVal(_) => "array"
    ObjectVal(_) => "object"
    NullVal => "null"
    UndefVal => "undefined"
  }
}

///|
/// Applies a chain of transforms in order; the first failure
/// stops the chain.
pub fn apply_chain(
  ts : Array[Transform],
  record : @protocol.Record,
) -> Result[@protocol.Record, String] {
  let mut current = record
  for t in ts {
    match apply(t, current) {
      Ok(next) => current = next
      Err(e) => return Err("\{t.source}: \{e}")
    }
  }
  Ok(current)
}
