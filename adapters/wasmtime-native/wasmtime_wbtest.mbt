// SPDX-License-Identifier: Apache-2.0
// Integration tests for adapters/wasmtime-native — loads the real
// operator wasm modules built by scripts/build-operators.sh and runs
// batches through the wasmtime C API. Requires libwasmtime (brew).
//
// Tests skip loudly (structured abort with instructions) when the
// module artifacts are absent: `moon build --target wasm` first.

///|
fn locate_module(op : String) -> String? {
  let release = "_build/wasm/release/build/apps/\{op}/\{op}.wasm"
  let debug = "_build/wasm/debug/build/apps/\{op}/\{op}.wasm"
  match @fs.exists(release) {
    Ok(true) => Some(release)
    _ =>
      match @fs.exists(debug) {
        Ok(true) => Some(debug)
        _ => None
      }
  }
}

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 9L,
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
test "identity operator runs through wasmtime" {
  let path = match locate_module("operator-identity") {
    Some(path) => path
    None => abort("operator module missing: run scripts/build-operators.sh")
  }
  let engine = operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  let instance = match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "identity",
      module_path: path,
      budget: Internal,
      config: "{}",
    }) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  assert_eq(instance.abi_version, 1)
  let input = [rec("alpha"), rec("beta")]
  match (instance.process)(input) {
    Ok(out) => {
      assert_eq(out.length(), 2)
      assert_eq(value_of(out[0]), "alpha")
      assert_eq(value_of(out[1]), "beta")
    }
    Err(e) => abort("process: \{e}")
  }
  (instance.close)()
}

///|
test "uppercase operator transforms through wasmtime" {
  let path = match locate_module("operator-upper") {
    Some(path) => path
    None => abort("operator module missing: run scripts/build-operators.sh")
  }
  let engine = operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  let instance = match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "upper",
      module_path: path,
      budget: Internal,
      config: "{}",
    }) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  match (instance.process)([rec("make"), rec("loud")]) {
    Ok(out) => {
      assert_eq(value_of(out[0]), "MAKE")
      assert_eq(value_of(out[1]), "LOUD")
    }
    Err(e) => abort("process: \{e}")
  }
  (instance.close)()
}

///|
test "missing module fails as InvalidSpec" {
  let engine = operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "gone",
      module_path: "/tmp/definitely-not-here.wasm",
      budget: Internal,
      config: "{}",
    }) {
    Err(@operator.InvalidSpec(_)) => ()
    Err(e) => abort("expected InvalidSpec, got \{e}")
    Ok(_) => abort("expected failure")
  }
}

///|
/// Instantiates the fixture operator with the given config text.
fn fixture_instance(config : String) -> @operator.OperatorInstance {
  let path = match locate_module("operator-fixture") {
    Some(path) => path
    None => abort("operator module missing: run scripts/build-operators.sh")
  }
  let engine = operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "fixture",
      module_path: path,
      budget: Internal,
      config,
    }) {
    Ok(instance) => instance
    Err(e) => abort("instantiate fixture (\{config}): \{e}")
  }
}

///|
test "guest refusal surfaces as GuestTrap with its message" {
  let instance = fixture_instance("{\"mode\":\"refuse\"}")
  match (instance.process)([rec("hello")]) {
    Err(@operator.GuestTrap(msg)) =>
      assert_true(msg.contains("fixture refused this batch on purpose"))
    Err(e) => abort("expected GuestTrap, got \{e}")
    Ok(_) => abort("expected the guest to refuse the batch")
  }
  (instance.close)()
}

///|
test "guest trap surfaces as a structured error" {
  let instance = fixture_instance("{\"mode\":\"trap\"}")
  match (instance.process)([rec("hello")]) {
    Err(@operator.GuestTrap(msg)) => assert_true(msg.contains("unreachable"))
    Err(e) => abort("expected GuestTrap, got \{e}")
    Ok(_) => abort("expected the guest to trap")
  }
  (instance.close)()
}

///|
test "runaway guest is stopped by the fuel budget" {
  let instance = fixture_instance("{\"mode\":\"spin\"}")
  match (instance.process)([rec("hello")]) {
    Err(@operator.BudgetExceeded(msg)) =>
      assert_true(msg.contains("fuel budget"))
    Err(e) => abort("expected BudgetExceeded, got \{e}")
    Ok(_) => abort("expected the guest to run out of fuel")
  }
  (instance.close)()
}

///|
test "operator-rejected config fails at instantiate" {
  let path = match locate_module("operator-fixture") {
    Some(path) => path
    None => abort("operator module missing: run scripts/build-operators.sh")
  }
  let engine = operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "fixture",
      module_path: path,
      budget: Internal,
      config: "{\"mode\":\"nonsense\"}",
    }) {
    Err(@operator.InvalidSpec(msg)) =>
      assert_true(msg.contains("rejected its config"))
    Err(e) => abort("expected InvalidSpec, got \{e}")
    Ok(_) => abort("expected the config to be rejected")
  }
}

///|
test "the v2 scalar exports answer through wasmtime (P26)" {
  let path = match locate_module("operator-scalar") {
    Some(path) => path
    None =>
      abort("operator-scalar.wasm missing — run: moon build --target wasm")
  }
  let engine = operator_engine(fn(module) {
    match @fs.read_file(module) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  let instance = match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "scalar-fixture",
      module_path: path,
      budget: User,
      config: "{}",
    }) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  // the module offers scalar calls; the batch face coexists
  let scalar = match instance.scalar_eval {
    Some(scalar) => scalar
    None => abort("the fixture module did not expose scalar_eval")
  }
  // tax: the design's own example (12.5 * 0.2 = 2.5)
  match scalar("tax", [SNum(12.5), SNum(0.2)]) {
    Ok(SNum(v)) => assert_true(v - 2.5 < 0.000001 && 2.5 - v < 0.000001)
    Ok(_) => abort("tax returned a non-number")
    Err(e) => abort("tax(12.5, 0.2): \{e}")
  }
  // shout: byte-comparable against mbel's upper() on ASCII input
  match scalar("shout", [SStr("hello sandbox")]) {
    Ok(SStr(s)) => assert_eq(s, "HELLO SANDBOX")
    Ok(_) => abort("shout returned a non-string")
    Err(e) => abort("shout: \{e}")
  }
  // a type mismatch is a structured refusal, never a crash
  match scalar("tax", [SStr("not a number"), SNum(1.0)]) {
    Err(EvalError(msg)) => assert_true(msg.contains("must be number"))
    Err(other) => abort("type mismatch produced \{other}")
    Ok(_) => abort("a string argument was accepted by tax")
  }
  // an unknown function is refused by name
  match scalar("nope", []) {
    Err(EvalError(msg)) => assert_true(msg.contains("no scalar function"))
    Err(other) => abort("unknown function produced \{other}")
    Ok(_) => abort("an unknown function was called")
  }
  (instance.close)()
}

///|
test "a v1-only module keeps scalar_eval absent (P26 coexistence)" {
  let path = match locate_module("operator-upper") {
    Some(path) => path
    None =>
      abort("operator-upper.wasm missing — run: moon build --target wasm")
  }
  let engine = operator_engine(fn(module) {
    match @fs.read_file(module) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  let instance = match
    (engine.instantiate)(@operator.OperatorSpec::{
      name: "v1-only",
      module_path: path,
      budget: User,
      config: "{}",
    }) {
    Ok(instance) => instance
    Err(e) => abort("instantiate: \{e}")
  }
  assert_true(instance.scalar_eval is None)
  (instance.close)()
}
