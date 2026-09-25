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
  /// A v2 scalar binding (P26): the resolved function name, the live
  /// module instance, and the per-batch call ceiling from the registry.
  Scalar(String, @operator.OperatorInstance, Int)
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
/// Resolves the function sets a spec's expression transforms
/// reference, in name order: `(name, revision)` pairs, which is what
/// the applied topology records so an operator can see which revision
/// a running pipeline was compiled against.
/// A reference that does not resolve fails the apply — publish time,
/// never mid-stream.
fn resolved_function_sets(
  spec : @spec.PipelineSpec,
  store : MetadataStore,
) -> Result[Array[(String, Int64)], String] {
  let names : Array[String] = []
  for t in spec.transforms {
    let name = match t {
      @spec.ExprTransform(_expr, functions) => functions
      @spec.WasmTransform(_module_id, _config) => ""
      // a scalar transform references a name in the node's scalar
      // registry, not a function set (P26): nothing to collect here
      @spec.ScalarTransform(_function) => ""
    }
    if name != "" {
      let mut seen = false
      for other in names {
        if other == name {
          seen = true
        }
      }
      if !seen {
        names.push(name)
      }
    }
  }
  names.sort_by(fn(a, b) { a.compare(b) })
  let out : Array[(String, Int64)] = []
  for name in names {
    match get_function_set(store, name) {
      Ok(set) => out.push((name, set.revision))
      Err(e) => return Err("function set \{name}: \{e}")
    }
  }
  Ok(out)
}

///|
/// Compiles one spec transform node into a runnable node. An
/// expression node that references a function set resolves it from the
/// local metadata store first: the set's functions are registered
/// before the publish-time static check, so a reference to a name the
/// set does not define is rejected at apply (README 决策 30).
fn compile_node(
  store : MetadataStore,
  data_dir : String,
  t : @spec.TransformSpec,
) -> Result[CompiledNode, String] {
  match t {
    ExprTransform(expr, set_name) => {
      let functions : Array[@transform.RuleFunction] = []
      if set_name != "" {
        let set = match get_function_set(store, set_name) {
          Ok(set) => set
          Err(e) => return Err("function set \{set_name}: \{e}")
        }
        for f in set.functions {
          functions.push(@transform.RuleFunction::{
            name: f.name,
            params: f.params,
            body: f.body,
          })
        }
      }
      match @transform.compile_with(expr, functions) {
        Ok(compiled) => Ok(Mbel(compiled))
        Err(e) => Err("transform \"\{expr}': \{e}")
      }
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
    ScalarTransform(function_name) => {
      // the binding happens HERE, at compile/apply time: the name must
      // resolve in the node's scalar registry, and the module must
      // actually offer the v2 scalar exports — a v1-only module is a
      // refusal with a reason, not a runtime surprise (P26)
      let registry = match load_scalar_registry(data_dir) {
        Ok(registry) => registry
        Err(e) => return Err(e)
      }
      let binding = match registry.lookup(function_name) {
        Some(binding) => binding
        None =>
          return Err(
            "scalar function \"\{function_name}\" is not registered in \{scalar_registry_path(data_dir)}",
          )
      }
      let engine = @wasmtime.operator_engine(fn(path) {
        match @fs.read_file(path) {
          Ok(bytes) => Ok(bytes)
          Err(e) => Err("\{e}")
        }
      })
      match
        (engine.instantiate)(@operator.OperatorSpec::{
          name: function_name,
          module_path: binding.module_path,
          budget: binding.tier,
          config: "{}",
        }) {
        Ok(instance) =>
          match instance.scalar_eval {
            Some(_) =>
              Ok(Scalar(function_name, instance, binding.max_calls_per_batch))
            None => {
              (instance.close)()
              Err(
                "scalar function \"\{function_name}\": module \{binding.module_path} is ABI v1-only (no mf_op_eval export)",
              )
            }
          }
        Err(e) => Err("scalar function \"\{function_name}\": \{e}")
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
          Ok(out) => {
            current = out
            // the wall clock is reported, not enforced (README 决策
            // 33): a call over its tier's hint is worth saying out
            // loud, and killing it would make the same batch pass or
            // fail by machine load
            match (instance.last_call_ms)() {
              Some(elapsed) =>
                if @operator.over_time_hint(Internal, elapsed) {
                  note(
                    "warning: operator call took \{elapsed}ms (internal hint \{@operator.call_timeout_hint_ms(Internal)}ms); fuel is the enforced budget",
                  )
                }
              None => ()
            }
          }
          Err(e) => return Err("wasm: \{e}")
        }
      Scalar(name, instance, max_calls) => {
        // v2 (P26): one evaluation per record — the record's value
        // crosses as a string (the design's record-mapping boundary;
        // richer mappings await a use case), and the guest's declared
        // parameter kinds judge whether that is acceptable. Failure is
        // fail-closed: the record does not pass, and neither does the
        // batch behind it.
        if current.length() > max_calls {
          return Err(
            "scalar \{name}: batch of \{current.length()} records exceeds its registered ceiling of \{max_calls} calls per batch",
          )
        }
        let eval = match instance.scalar_eval {
          Some(eval) => eval
          None =>
            return Err("scalar \{name}: the instance lost its scalar binding")
        }
        let out : Array[@protocol.Record] = []
        for r in current {
          let value = @utf8.decode_lossy(r.value[0:r.value.length()])
          match eval(name, [@operator.SStr(value)]) {
            Ok(@operator.SStr(transformed)) =>
              out.push(@protocol.Record::{
                timestamp: r.timestamp,
                key: r.key,
                value: @utf8.encode(transformed[0:transformed.length()]),
                headers: r.headers,
              })
            Ok(_) =>
              return Err(
                "scalar \{name}: returned a non-string for a record value (a scalar transform maps values to values)",
              )
            Err(e) => return Err("scalar \{name}: \{e}")
          }
        }
        current = out
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
  let store = file_metadata_store(data_dir)
  let chain : Array[CompiledNode] = []
  for t in applied.spec.transforms {
    match compile_node(store, data_dir, t) {
      Ok(node) => chain.push(node)
      Err(e) => return Err(e)
    }
  }
  Ok((applied.pipeline, chain))
}
