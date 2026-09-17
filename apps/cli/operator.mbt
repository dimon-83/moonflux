// SPDX-License-Identifier: Apache-2.0
// operator: the management CLI for operator modules (P5, the first
// slice of the SmartModule-shaped command family from
// docs/cli-roadmap.md §3.2).
//
// Everything here runs the module through the *real* host: the same
// wasmtime adapter, the same ABI v1 handshake, the same init round
// trip that production data-path use performs. A verify that passes
// here is the same verify the broker would do before loading an
// operator — there is no second, softer checker to disagree with.

///|
/// `moonflux operator <verb> [flags]`
fn cmd_operator(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("operator: missing verb (verify, describe, list)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "verify" => operator_verify(rest)
    "describe" => operator_describe(rest)
    "list" => operator_list(rest)
    _ =>
      fail("operator: unknown verb '\{verb}' (known: verify, describe, list)")
  }
}

///|
/// Loads and handshakes with a module through the production host.
/// Every failure mode the host can report is surfaced verbatim: a
/// missing export, a wrong ABI version, an import segment (the host
/// instantiates with no imports, so a module wanting WASI is refused),
/// or a file that is not a module at all.
fn operator_load(path : String) -> Result[@operator.OperatorInstance, String] {
  let engine = @wasmtime.operator_engine(fn(path) {
    match @fs.read_file(path) {
      Ok(bytes) => Ok(bytes)
      Err(e) => Err("\{e}")
    }
  })
  let name = match path.rev_split_once("/") {
    Some((_, name)) => name.to_owned()
    None => path
  }
  match
    (engine.instantiate)(@operator.OperatorSpec::{
      name,
      module_path: path,
      budget: Internal,
      config: "{}",
    }) {
    Ok(instance) => Ok(instance)
    Err(e) => Err("\{e}")
  }
}

///|
/// `moonflux operator verify <path.wasm>` — exit 0 iff the module
/// loads, speaks ABI v1, and accepts an empty init config.
fn operator_verify(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let path = flags.require("file")
  match operator_load(path) {
    Ok(instance) => {
      println("ok: \{path} speaks ABI v1 and accepted init")
      (instance.close)()
      cli_exit(0)
    }
    Err(e) => fail("verify: \{e}")
  }
}

///|
/// `moonflux operator describe <path.wasm>` — what the host learned:
/// ABI version, the budget envelope a data-path deployment would use,
/// and the file's size. Budget numbers come from core/operator (the
/// same constants the runtime enforces), so they cannot drift from it.
fn operator_describe(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let path = flags.require("file")
  let size = match @fs.exists(path) {
    Ok(true) =>
      match @fs.read_file(path) {
        Ok(bytes) => bytes.length()
        Err(e) => fail("describe: \{e}")
      }
    _ => fail("describe: no such file \{path}")
  }
  let instance = match operator_load(path) {
    Ok(instance) => instance
    Err(e) => fail("describe: \{e}")
  }
  println("module      \{path}")
  println("size        \{size} bytes")
  println(
    "abi_version \{instance.abi_version} (host speaks \{@operator.ABI_VERSION})",
  )
  println(
    "budget      internal: \{@operator.max_records_per_call(Internal)} records / \{@operator.fuel_per_call(Internal)} fuel per call",
  )
  println(
    "budget      user: \{@operator.max_records_per_call(User)} records / \{@operator.fuel_per_call(User)} fuel",
  )
  println(
    "budget      tenant: \{@operator.max_records_per_call(Tenant)} records / \{@operator.fuel_per_call(Tenant)} fuel",
  )
  (instance.close)()
  cli_exit(0)
}

///|
/// `moonflux operator list [--dir DIR]` — the operator artifacts the
/// repo has built, each verified through the host so the listing shows
/// health, not just filenames.
fn operator_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let dir = flags.get("dir") |> unwrap_or("_build/wasm/debug/build/apps")
  let entries = match @fs.list_dir(dir) {
    Ok(entries) => entries
    Err(e) => fail("operator list: \{e}")
  }
  for entry in entries {
    if !entry.has_prefix("operator-") {
      continue
    }
    let path = "\{dir}/\{entry}/\{entry}.wasm"
    match @fs.exists(path) {
      Ok(true) => {
        let status = match operator_load(path) {
          Ok(instance) => {
            (instance.close)()
            "ok"
          }
          Err(e) => "unusable: \{e}"
        }
        println("\{entry}\t\{status}")
      }
      _ => ()
    }
  }
  cli_exit(0)
}
