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
/// Clock builtins that a rule asset may not reference. mbel's `now`
/// reads the host clock, and a rule whose result depends on when it was
/// evaluated cannot be replayed after a crash — the determinism red
/// line (AGENTS §5) therefore extends from the kernel to the rule
/// assets. Textual token scan: a pragmatic first cut, documented as
/// such; it over-matches only inside string literals and comments.
pub fn check_purity(source : String) -> Result[Unit, String] {
  let clock_builtins = ["now"]
  let token = StringBuilder::new()
  for i in 0..<source.length() {
    let c = source[i]
    let ident = (c >= 97 && c <= 122) ||
      (c >= 65 && c <= 90) ||
      (c >= 48 && c <= 57) ||
      c == 95 // letter, digit, underscore
    if ident {
      token.write_char(c.to_int().unsafe_to_char())
    } else {
      let word = token.to_string()
      token.reset()
      for banned in clock_builtins {
        if word == banned {
          return Err(
            "rule asset references the clock builtin '\{word}': evaluation must stay deterministic for replay",
          )
        }
      }
    }
  }
  let word = token.to_string()
  for banned in clock_builtins {
    if word == banned {
      return Err(
        "rule asset references the clock builtin '\{word}': evaluation must stay deterministic for replay",
      )
    }
  }
  Ok(())
}

///|
/// Internal budget tier (report 5.5: 内部级). Constants keep the P1
/// surface honest; per-tenant tiers arrive with multi-tenancy (P3+).
pub const BUDGET_MAX_NODES = 10000

///|
pub const BUDGET_MAX_DEPTH = 100

///|
pub const BUDGET_MAX_STEPS = 100000

///|
/// One custom function of a rule asset: an expression body with an
/// explicit parameter list. Parameters are required — mbel can also
/// auto-extract free identifiers from a body, and that convenience is
/// deliberately not exposed here: a typo in a body must fail the
/// publish-time check, never silently become a parameter.
pub(all) struct RuleFunction {
  name : String
  params : Array[String]
  body : String
} derive(Debug, Eq, Show)

///|
/// How long an error message may get before it is truncated. Measured
/// (P6 evaluation): mbel's call-depth error nests one frame per level,
/// so a 256-level recursion produces ~4.4 KB of text — per failing
/// record. A bounded message keeps a rule that fails on every record
/// from turning into a log flood.
pub const MAX_ERROR_CHARS = 512

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
  compile_with(expr, [])
}

///|
/// Compiles an expression with a function set registered first. Order
/// is load-bearing: the strict publish-time check consults the engine's
/// function table, so custom names only resolve (and only get
/// type/budget coverage) when the set is registered before it.
///
/// The functions are mbel's expression-body definitions — deterministic
/// by construction (recursion capped, Vm program cached, inside the
/// step budget), which is what makes host-side registration acceptable
/// for trusted, reviewed assets (README 决策 30).
pub fn compile_with(
  expr : String,
  functions : Array[RuleFunction],
) -> Result[Transform, String] {
  let engine = @mengine.new()
  engine.set_limits(BUDGET_MAX_NODES, BUDGET_MAX_DEPTH, BUDGET_MAX_STEPS)
  engine.set_engine(@mengine.Vm)
  if functions.length() > 0 {
    let _ = engine.add_expression_functions(to_user_functions(functions), None) catch {
      e => return Err(bounded("function set: \{error_text(e)}"))
    }
  }
  // strict publish-time check: probe context mirrors the runtime
  // field types (value/key strings, numeric timestamp/headers_count)
  let probe = @ast.ObjectVal([
    ("value", @ast.StrVal("a")),
    ("key", @ast.StrVal("")),
    ("timestamp", @ast.NumVal(1726000000000.0)),
    ("headers_count", @ast.NumVal(0.0)),
  ])
  let _ = engine.eval_expr_checked(expr, probe) catch {
    e => return Err(bounded("static check: \{error_text(e)}"))
  }
  let compiled = engine.compile(expr) catch {
    e => return Err(bounded("compile: \{error_text(e)}"))
  }
  Ok(Transform::{ source: expr, expr: compiled })
}

///|
/// Validates a whole function set at publish time, independently of any
/// expression that uses it. Registration on a scratch engine is the
/// authority for everything mbel defines (name syntax, keywords,
/// `$env`, aggregate conflicts, duplicate names, parameter rules,
/// non-empty and syntactically valid bodies) — one rule, one place —
/// and the purity scan adds this project's determinism requirement
/// (AGENTS §5).
///
/// Known boundary, measured: mbel type-infers a body from its call
/// sites, so this pass cannot type-check bodies. Types are covered when
/// a spec actually uses the set (compile_with).
pub fn validate_functions(
  functions : Array[RuleFunction],
) -> Result[Unit, String] {
  if functions.length() == 0 {
    return Err("function set must define at least one function")
  }
  let engine = @mengine.new()
  engine.set_limits(BUDGET_MAX_NODES, BUDGET_MAX_DEPTH, BUDGET_MAX_STEPS)
  engine.set_engine(@mengine.Vm)
  let _ = engine.add_expression_functions(to_user_functions(functions), None) catch {
    e => return Err(error_text(e))
  }
  for f in functions {
    // the function's own name and parameters are scanned too: a name
    // that collides with a clock builtin is rejected rather than
    // silently shadowing it (fail-closed direction, README 决策 30)
    match check_purity(f.name) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    for p in f.params {
      match check_purity(p) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    match check_purity(f.body) {
      Ok(_) => ()
      Err(e) => return Err("function \"\{f.name}\": \{e}")
    }
  }
  Ok(())
}

///|
fn to_user_functions(
  functions : Array[RuleFunction],
) -> Array[@mengine.UserFunctionDef] {
  let out : Array[@mengine.UserFunctionDef] = []
  for f in functions {
    out.push(@mengine.UserFunctionDef::{
      name: f.name,
      params: Some(f.params),
      body: f.body,
    })
  }
  out
}

///|
/// Truncates a message to MAX_ERROR_CHARS, saying so when it does.
fn bounded(text : String) -> String {
  if text.length() <= MAX_ERROR_CHARS {
    return text
  }
  let kept = text[0:MAX_ERROR_CHARS].to_string()
  "\{kept}… (\{text.length() - MAX_ERROR_CHARS} more chars)"
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
    e => return Err(bounded("eval: \{error_text(e)}"))
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
