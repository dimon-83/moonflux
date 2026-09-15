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
