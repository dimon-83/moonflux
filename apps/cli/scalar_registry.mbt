// SPDX-License-Identifier: Apache-2.0
// apps/cli/scalar_registry.mbt (P26): the node's scalar-function
// registry — which names map to which sandboxed modules.
//
// The design (docs/operator-abi-v2-scalar.md, open question 4) left
// "who writes the name -> module mapping" to implementation. The
// answer here follows the project's grain: it is NODE configuration,
// a versioned document beside auth.json and the function sets, read
// and validated at load, and the binding happens at apply time — a
// spec references a name, the node decides what that name means, the
// same stance as decision 30's function-set revision binding.

///|
fn scalar_registry_path(data_dir : String) -> String {
  "\{data_dir}/scalar-functions.json"
}

///|
/// One registered scalar function: where its module lives, its budget
/// tier (the fuel envelope), and how many calls one batch may make.
struct ScalarBinding {
  module_path : String
  tier : @operator.BudgetTier
  max_calls_per_batch : Int
}

///|
struct ScalarRegistry {
  revision : Int64
  functions : Map[String, ScalarBinding]
}

///|
fn ScalarRegistry::lookup(
  self : ScalarRegistry,
  name : String,
) -> ScalarBinding? {
  self.functions.get(name)
}

///|
/// Loads the registry. Absent file = an empty registry (scalar
/// transforms simply cannot resolve — an apply-time refusal with the
/// path in the message). A corrupt document is an error, not an empty
/// registry: "your bindings are gone" must never be silent (the same
/// stance as groups.json and the profile config).
fn load_scalar_registry(data_dir : String) -> Result[ScalarRegistry, String] {
  let path = scalar_registry_path(data_dir)
  match @fs.exists(path) {
    Ok(false) => Ok(ScalarRegistry::{ revision: 0L, functions: {} })
    _ => {
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(e) => return Err("read \{path}: \{e}")
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      let json = @json.parse(text[0:text.length()]) catch {
        e => return Err("corrupt \{path}: \{e}")
      }
      let obj = match json {
        Object(obj) => obj
        _ => return Err("corrupt \{path}: expected a JSON object")
      }
      let mut revision = 0L
      match obj.get("revision") {
        Some(Number(n)) => revision = n.to_int64()
        Some(_) => return Err("corrupt \{path}: revision must be a number")
        None => ()
      }
      let functions : Map[String, ScalarBinding] = {}
      match obj.get("functions") {
        Some(Array(entries)) =>
          for entry in entries {
            let item = match entry {
              Object(item) => item
              _ =>
                return Err(
                  "corrupt \{path}: every function entry must be an object",
                )
            }
            for key in item.keys() {
              if key != "name" &&
                key != "module" &&
                key != "tier" &&
                key != "max_calls_per_batch" {
                return Err(
                  "corrupt \{path}: unknown field \"\{key}\" in a function entry (name, module, tier, max_calls_per_batch)",
                )
              }
            }
            let name = match item.get("name") {
              Some(String(name)) => name
              _ => return Err("corrupt \{path}: a function entry has no name")
            }
            let module_path = match item.get("module") {
              Some(String(module_path)) => module_path
              _ => return Err("corrupt \{path}: \{name} has no module path")
            }
            let tier = match item.get("tier") {
              Some(String("internal")) => @operator.Internal
              Some(String("user")) => @operator.User
              Some(_) =>
                return Err(
                  "corrupt \{path}: \{name}'s tier must be internal or user",
                )
              None => @operator.User
            } // the narrow envelope is the default
            let max_calls = match item.get("max_calls_per_batch") {
              Some(Number(n)) =>
                if n < 1.0 {
                  return Err(
                    "corrupt \{path}: \{name}'s max_calls_per_batch must be positive",
                  )
                } else {
                  n.to_int()
                }
              Some(_) =>
                return Err(
                  "corrupt \{path}: \{name}'s max_calls_per_batch must be a number",
                )
              None => 100000
            }
            if functions.get(name) is Some(_) {
              return Err("corrupt \{path}: duplicate function name \{name}")
            }
            functions[name] = ScalarBinding::{
              module_path,
              tier,
              max_calls_per_batch: max_calls,
            }
          }
        Some(_) => return Err("corrupt \{path}: functions must be an array")
        None => ()
      }
      for key in obj.keys() {
        if key != "revision" && key != "functions" {
          return Err("corrupt \{path}: unknown field \"\{key}\"")
        }
      }
      Ok(ScalarRegistry::{ revision, functions })
    }
  }
}
