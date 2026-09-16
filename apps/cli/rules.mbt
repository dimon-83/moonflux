// Compiled transform chain: mbel expression rules (per record) and
// wasm operator modules (per batch), hot-reloaded when topology.json
// changes. "Rules take effect in seconds": apply rewrites the file,
// the next request picks up the new chain — no server restart. A
// reload that fails validation keeps the previous rules and warns
// (never silent, never empty).

///|
/// One compiled transform node.
priv enum CompiledNode {
  Mbel(@transform.Transform)
  Wasm(@operator.OperatorInstance)
}

///|
struct RuleState {
  mut chain : Array[CompiledNode]
  mut pipeline : String
  mut stamp : Int64
}

///|
fn RuleState::new() -> RuleState {
  RuleState::{ chain: [], pipeline: "", stamp: -1L }
}

///|
/// Compiles one spec transform node into a runnable node.
fn compile_node(t : @spec.TransformSpec) -> Result[CompiledNode, String] {
  match t {
    ExprTransform(expr) =>
      match @transform.compile(expr) {
        Ok(compiled) => Ok(Mbel(compiled))
        Err(e) => Err("transform \"\{expr}': \{e}")
      }
    WasmTransform(module_id, config) => {
      let engine = @wasmtime.operator_engine(fn(path) {
        match @fs.read_file(path) {
          Ok(bytes) => Ok(bytes)
          Err(e) => Err("\{e}")
        }
      })
      match
        (engine.instantiate)(@operator.OperatorSpec::{
          name: module_id,
          module_path: module_id,
          budget: Internal,
          config,
        }) {
        Ok(instance) => Ok(Wasm(instance))
        Err(e) => Err("wasm operator \"\{module_id}\": \{e}")
      }
    }
  }
}

///|
/// Applies a compiled chain over a batch. mbel nodes run per record,
/// wasm nodes run per batch (their ABI v1 envelope IS a batch).
fn apply_nodes(
  nodes : Array[CompiledNode],
  records : Array[@protocol.Record],
) -> Result[Array[@protocol.Record], String] {
  let mut current = records
  for node in nodes {
    match node {
      Mbel(t) => {
        let out : Array[@protocol.Record] = []
        for r in current {
          match @transform.apply(t, r) {
            Ok(next) => out.push(next)
            Err(e) => return Err("mbel: \{e}")
          }
        }
        current = out
      }
      Wasm(instance) =>
        match (instance.process)(current) {
          Ok(out) => current = out
          Err(e) => return Err("wasm: \{e}")
        }
    }
  }
  Ok(current)
}

///|
/// Re-reads the applied topology when its mtime moved. Called before
/// request dispatch; a stat per request is the whole cost.
fn RuleState::sync(self : RuleState, data_dir : String) -> Unit {
  let path = topology_path(data_dir)
  let stamp = match @fs.mtime(path) {
    Ok(stamp) => stamp
    Err(_) => return // nothing applied; keep current (empty) chain
  }
  if stamp == self.stamp {
    return
  }
  match load_chain_from_topology(data_dir) {
    Ok((name, chain)) => {
      self.chain = chain
      self.pipeline = name
      self.stamp = stamp
      if chain.length() > 0 {
        println(
          "rules active: pipeline \{self.pipeline}, \{chain.length()} transform(s) (version \{stamp})",
        )
      }
    }
    Err(e) => {
      // keep previous rules; stamp anyway so a fixed spec (new mtime
      // from the next apply) triggers exactly one fresh attempt
      self.stamp = stamp
      println("warning: rule reload rejected, keeping previous rules: \{e}")
    }
  }
}

///|
/// Compiles the applied spec's transform chain (compile-once assets).
fn load_chain_from_topology(
  data_dir : String,
) -> Result[(String, Array[CompiledNode]), String] {
  let applied = match load_applied(data_dir) {
    Some(applied) => applied
    None => return Ok(("", []))
  }
  let chain : Array[CompiledNode] = []
  for t in applied.spec.transforms {
    match compile_node(t) {
      Ok(node) => chain.push(node)
      Err(e) => return Err(e)
    }
  }
  Ok((applied.pipeline, chain))
}
