// Rule state for the serving path: the compiled transform chain of
// the applied pipeline, hot-reloaded when topology.json changes.
// "Rules take effect in seconds": apply rewrites the file, the next
// request picks up the new chain — no server restart. A reload that
// fails validation keeps the previous rules and warns (never silent,
// never empty).

///|
struct RuleState {
  mut chain : Array[@transform.Transform]
  mut pipeline : String
  mut stamp : Int64
}

///|
fn RuleState::new() -> RuleState {
  RuleState::{ chain: [], pipeline: "", stamp: -1L }
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
          "rules active: pipeline \{name}, \{chain.length()} transform(s) (version \{stamp})",
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
) -> Result[(String, Array[@transform.Transform]), String] {
  let applied = match load_applied(data_dir) {
    Some(applied) => applied
    None => return Ok(("", []))
  }
  let chain : Array[@transform.Transform] = []
  for t in applied.spec.transforms {
    let expr = match t {
      ExprTransform(expr) => expr
    }
    match @transform.compile(expr) {
      Ok(compiled) => chain.push(compiled)
      Err(e) => return Err("transform \"\{expr}\": \{e}")
    }
  }
  Ok((applied.pipeline, chain))
}
