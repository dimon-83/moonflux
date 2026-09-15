// SPDX-License-Identifier: Apache-2.0
// core/pipeline: compiles a validated PipelineSpec into the process
// topology that executes it, and diffs topologies for `plan` output.
// Pure computation (kernel red lines); the CLI owns persistence and
// execution.

///|
/// One executable process in the compiled topology.
pub(all) struct Process {
  name : String
  role : String
  /// Capability required to run this process: "native" runs today;
  /// "mbel-p1" is compiled but refuses to execute until the P1
  /// dynamic-rule milestone lands.
  capability : String
  /// Human-readable configuration snapshot (plan/apply display).
  detail : String
} derive(Debug, Eq, Show)

///|
/// The compiled form of one pipeline: the processes that make up its
/// runtime path.
pub(all) struct Topology {
  pipeline : String
  topic : String
  processes : Array[Process]
} derive(Debug, Eq, Show)

///|
/// One difference between two topologies.
pub(all) enum DiffOp {
  /// Process present only in the new topology.
  Add(Process)
  /// Process present in both with a different configuration.
  Update(String, String, String)
  /// Process present only in the old topology (by name).
  Remove(String)
} derive(Debug, Eq, Show)

///|
/// Compiles a validated spec. Deterministic: the same spec always
/// compiles to the same topology (plan diffs stay stable).
pub fn compile(spec : @spec.PipelineSpec) -> Topology {
  let processes : Array[Process] = []
  processes.push(Process::{
    name: "broker",
    role: "broker",
    capability: "native",
    detail: "topic \{spec.topic.name}, single partition",
  })
  let (role, detail) = match spec.source {
    FileSource(path) => ("source-runner", "file source: \{path}")
    // non-exhaustive guard: v1alpha1 has exactly one source kind
  }
  processes.push(Process::{
    name: "source-runner",
    role,
    capability: "native",
    detail,
  })
  for i, t in spec.transforms {
    let expr = match t {
      ExprTransform(expr) => expr
    }
    processes.push(Process::{
      name: "transform-\{i}",
      role: "transform-runner",
      capability: "mbel-p1",
      detail: "expr transform: \{expr}",
    })
  }
  processes.push(Process::{
    name: "sink-runner",
    role: "sink-runner",
    capability: "native",
    detail: "stdout sink",
  })
  Topology::{ pipeline: spec.metadata_name, topic: spec.topic.name, processes }
}

///|
/// True when every process in the topology can execute on the P0
/// runtime (no P1-only capabilities).
pub fn runnable(topology : Topology) -> Bool {
  for p in topology.processes {
    if p.capability != "native" {
      return false
    }
  }
  true
}

///|
/// Diffs two topologies by process name. `old` absent means a full
/// create.
pub fn diff(old : Topology?, new : Topology) -> Array[DiffOp] {
  let ops : Array[DiffOp] = []
  let old_map : Map[String, Process] = {}
  match old {
    Some(t) =>
      for p in t.processes {
        old_map[p.name] = p
      }
    None => ()
  }
  let new_names : Map[String, Bool] = {}
  for p in new.processes {
    new_names[p.name] = true
    match old_map.get(p.name) {
      None => ops.push(Add(p))
      Some(previous) =>
        if previous.detail != p.detail ||
          previous.role != p.role ||
          previous.capability != p.capability {
          ops.push(Update(p.name, previous.detail, p.detail))
        }
    }
  }
  for name, _ in old_map {
    match new_names.get(name) {
      Some(_) => ()
      None => ops.push(Remove(name))
    }
  }
  ops
}

///|
/// Renders diff ops as human-readable lines (plan output).
pub fn render_diff(ops : Array[DiffOp]) -> String {
  let sb = StringBuilder::new()
  let mut adds = 0
  let mut updates = 0
  let mut removes = 0
  for op in ops {
    match op {
      Add(p) => {
        adds += 1
        sb.write_string("  + \{p.name} (\{p.role}): \{p.detail}\n")
      }
      Update(name, old_detail, new_detail) => {
        updates += 1
        sb.write_string("  ~ \{name}: \{old_detail} -> \{new_detail}\n")
      }
      Remove(name) => {
        removes += 1
        sb.write_string("  - \{name}\n")
      }
    }
  }
  if ops.is_empty() {
    sb.write_string("  (no changes)\n")
  }
  sb.write_string(
    "diff: \{adds} to add, \{updates} to update, \{removes} to remove\n",
  )
  sb.to_string()
}
