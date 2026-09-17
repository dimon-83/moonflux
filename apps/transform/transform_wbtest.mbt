// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for apps/transform — publish-time checks, budget
// behavior, and per-record evaluation semantics.

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 1726000000000L,
    key: b"",
    value: @utf8.encode(value[0:value.length()]),
    headers: [],
  }
}

///|
fn must_apply(t : Transform, r : @protocol.Record) -> @protocol.Record {
  match apply(t, r) {
    Ok(out) => out
    Err(e) => abort("apply: \{e}")
  }
}

///|
fn value_of(r : @protocol.Record) -> String {
  @utf8.decode_lossy(r.value[0:r.value.length()])
}

///|
test "compile once, evaluate per record (Vm program cache)" {
  let t = match compile("upper(value) + \"!\"") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  assert_eq(value_of(must_apply(t, rec("hello"))), "HELLO!")
  assert_eq(value_of(must_apply(t, rec("again"))), "AGAIN!")
  // expression text is preserved as the rule asset
  assert_eq(t.source, "upper(value) + \"!\"")
}

///|
test "context exposes record fields" {
  let t = match
    compile(
      "timestamp > 0 && key == \"\" ? value + \"-plain\" : value + \"-keyed\"",
    ) {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  assert_eq(value_of(must_apply(t, rec("a"))), "a-plain")
  let keyed = @protocol.Record::{
    timestamp: 1L,
    key: @utf8.encode("k"[0:1]),
    value: @utf8.encode("a"[0:1]),
    headers: [],
  }
  assert_eq(value_of(must_apply(t, keyed)), "a-keyed")
  // headers_count is readable too
  let t2 = match compile("headers_count == 0 ? value : value + \"!\"") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  assert_eq(value_of(must_apply(t2, rec("b"))), "b")
}

///|
test "syntax errors rejected at publish time" {
  assert_true(compile("value +") is Err(_))
  assert_true(compile("(value") is Err(_))
  assert_true(compile("") is Err(_))
}

///|
test "unknown functions rejected at publish time" {
  assert_true(compile("nosuchfn(value)") is Err(_))
}

///|
test "non-string result is a fail-closed error" {
  let t = match compile("1 + 1") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  assert_true(apply(t, rec("x")) is Err(_))
}

///|
test "unknown variables rejected at publish time (strict names)" {
  // the probe context pins the exposed field set: anything else is
  // an unknown name and must be caught when rules are applied
  assert_true(compile("nothere + \"!\"") is Err(_))
  assert_true(compile("valu + \"!\"") is Err(_))
  // the exposed field set itself passes the name check
  assert_true(compile("value + key") is Ok(_))
}

///|
test "node budget rejects oversized expressions at compile" {
  // 5000 additions = >10000 AST nodes, over the internal tier budget
  let sb = StringBuilder::new()
  sb.write_string("\"a\"")
  for _i in 0..<5000 {
    sb.write_string(" + \"b\"")
  }
  assert_true(compile(sb.to_string()) is Err(_))
}

///|
test "apply_chain composes in order and stops at first failure" {
  let t1 = match compile("upper(value)") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  let t2 = match compile("value + \"!\"") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  match apply_chain([t1, t2], rec("go")) {
    Ok(r) => assert_eq(value_of(r), "GO!")
    Err(e) => abort("chain failed: \{e}")
  }
  // failing middle link surfaces which rule failed
  let bad = match compile("1 + 1") {
    Ok(t) => t
    Err(e) => abort("compile: \{e}")
  }
  match apply_chain([t1, bad, t2], rec("go")) {
    Err(e) => assert_true(e.contains("1 + 1"))
    Ok(_) => abort("chain should fail")
  }
}

// ---------------------------------------------------------------------
// Function sets (P6): expression-body custom functions. All semantics
// below were probed against mbel 0.3.3 before being pinned here —
// see .scratch/moonflux-p6/issues/36-function-set-assets.md §评估校核.

///|
fn userfn(name : String, params : Array[String], body : String) -> RuleFunction {
  RuleFunction::{ name, params, body }
}

///|
test "a custom function resolves in the static check and at runtime" {
  let t = match
    compile_with("shout(value)", [userfn("shout", ["x"], "upper(x) + \"!\"")]) {
    Ok(t) => t
    Err(e) => abort("compile_with: \{e}")
  }
  let out = match apply(t, rec("abc")) {
    Ok(record) => @utf8.decode_lossy(record.value[0:record.value.length()])
    Err(e) => abort("apply: \{e}")
  }
  assert_eq(out, "ABC!")
}

///|
test "an unknown function still fails the static check" {
  assert_true(compile_with("no_such_fn(value)", []) is Err(_))
  // a name that is not in the registered set is equally unknown
  assert_true(
    compile_with("other_fn(value)", [userfn("shout", ["x"], "upper(x)")])
    is Err(_),
  )
}

///|
test "validation is use-driven: an unreferenced broken function is accepted" {
  // mbel type-infers function bodies from their call sites, so a set
  // is only validated where the checked expression reaches. This is
  // the documented boundary of the publish-time guarantee (T36):
  // syntactic + purity checks cover the whole asset, type checking
  // covers the used closure.
  assert_true(
    compile_with("upper(value)", [userfn("broken", ["x"], "x / 0")]) is Ok(_),
  )
}

///|
test "unbounded recursion is rejected at publish time" {
  let fns = [
    userfn("ping", ["n"], "if n <= 0 { 0 } else { pong(n - 1) }"),
    userfn("pong", ["n"], "ping(n - 1)"),
  ]
  // the check evaluates the literal call, so mbel's 256-level cap
  // fires before any record flows
  assert_true(compile_with("ping(100000)", fns) is Err(_))
}

///|
test "data-driven recursion fails closed at runtime" {
  let fns = [
    userfn("ping", ["n"], "if n <= 0 { 0 } else { pong(n - 1) }"),
    userfn("pong", ["n"], "ping(n - 1)"),
  ]
  // the check sees headers_count = 0 and terminates; at runtime a
  // record with 300 headers drives the depth past mbel's cap
  let t = match
    compile_with("upper(value) + string(ping(headers_count))", fns) {
    Ok(t) => t
    Err(e) => abort("compile_with: \{e}")
  }
  let many = Array::makei(300, fn(_i : Int) {
    (@utf8.encode("k"), @utf8.encode("v"))
  })
  let record = @protocol.Record::{
    timestamp: 0L,
    key: @utf8.encode("k"),
    value: @utf8.encode("abc"),
    headers: many,
  }
  // fail-closed: Err, never a mangled record
  assert_true(apply(t, record) is Err(_))
}

///|
test "the compiled surface takes ternaries; if-blocks belong in bodies" {
  let fns = [userfn("yes", ["x"], "x == \"a\" ? \"hit\" : \"miss\"")]
  assert_true(compile_with("value == \"a\" ? \"yes\" : \"no\"", []) is Ok(_))
  assert_true(compile_with("yes(value)", fns) is Ok(_))
  // top-level if-blocks are a check-engine construct only: the Vm
  // compile stage rejects them (observed), so they never reach service
  assert_true(
    compile_with("if value == \"a\" { \"yes\" } else { \"no\" }", []) is Err(_),
  )
}

///|
test "check_purity rejects clock builtins and passes pure bodies" {
  assert_true(check_purity("upper(value)") is Ok(_))
  assert_true(check_purity("len(value) + timestamp") is Ok(_))
  // mbel's only non-deterministic builtin, standalone and embedded
  assert_true(check_purity("now") is Err(_))
  assert_true(check_purity("now - 1000") is Err(_))
  // identifiers that merely contain the letters are fine
  assert_true(check_purity("known_value + newsletter") is Ok(_))
}

///|
test "validate_functions accepts a good set and rejects the rest" {
  assert_true(
    validate_functions([userfn("shout", ["x"], "upper(x) + \"!\"")]) is Ok(_),
  )
  // mbel's name rules: keywords and non-identifiers are out
  assert_true(validate_functions([userfn("if", ["x"], "upper(x)")]) is Err(_))
  assert_true(validate_functions([userfn("1bad", ["x"], "upper(x)")]) is Err(_))
  // duplicate names and duplicate parameters inside one set
  assert_true(
    validate_functions([
      userfn("a", ["x"], "upper(x)"),
      userfn("a", ["y"], "upper(y)"),
    ])
    is Err(_),
  )
  assert_true(
    validate_functions([userfn("a", ["x", "x"], "upper(x)")]) is Err(_),
  )
  // empty and syntactically invalid bodies
  assert_true(validate_functions([userfn("a", ["x"], "")]) is Err(_))
  assert_true(validate_functions([userfn("a", ["x"], "upper(")]) is Err(_))
  // an empty set is not an asset
  assert_true(validate_functions([]) is Err(_))
  // purity: the clock builtin is rejected in bodies, names and params
  assert_true(validate_functions([userfn("a", ["x"], "now")]) is Err(_))
  assert_true(validate_functions([userfn("now", ["x"], "upper(x)")]) is Err(_))
  assert_true(
    validate_functions([userfn("a", ["now"], "upper(now)")]) is Err(_),
  )
}

///|
test "long error text is truncated, short text is untouched" {
  let fns = [
    userfn("ping", ["n"], "if n <= 0 { 0 } else { pong(n - 1) }"),
    userfn("pong", ["n"], "ping(n - 1)"),
  ]
  match compile_with("ping(100000)", fns) {
    Ok(_) => abort("expected a publish-time rejection")
    Err(e) => {
      assert_true(e.length() <= MAX_ERROR_CHARS + 40)
      assert_true(e.contains("more chars"))
    }
  }
  match compile_with("no_such_fn(value)", []) {
    Ok(_) => abort("expected a rejection")
    Err(e) => assert_true(!e.contains("more chars"))
  }
}
