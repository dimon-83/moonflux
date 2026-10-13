// SPDX-License-Identifier: Apache-2.0
// The VIEW MODEL: the compiled topology, projected into the nodes and edges a
// console renders.
//
// Why this lives in the kernel:
//
//   * the page must not derive the topology itself (P4: the editor renders the
//     spec and the compiler, it never defines a second truth), and two
//     derivations of one graph drift apart;
//   * `core/pipeline` already compiles the processes, so this is a PURE,
//     DETERMINISTIC projection of that result — the CLI and the browser call
//     the same function and can be compared byte for byte (the P37-3 gate does
//     exactly that, and it is meant to be trivially true: there is only one
//     implementation).
//
// The edges are a documented RULE over the same processes, not a second
// opinion about them:
//
//   connector source :  source-runner -> broker        (append: the source writes)
//   topic source     :  broker -> source-runner        (read: the relay reads its
//                       source-runner -> broker         own log, then appends)
//   read path        :  broker -> transform-0 -> ... -> transform-N -> sink
//                       (or broker -> sink when the chain is empty)
//
// `kind` is "append" / "read" / "feed" / "consume" and says what travels along
// the edge; the console colours by it (Studio's grey edges are the same idea,
// expressed in this platform's terms).

///|
/// The view model's own version. The page asserts it, exactly like the editor
/// ABI: a model the page does not understand must be a refusal, not a guess.
pub const VIEW_MODEL_VERSION : Int32 = 1

///|
/// The kind of a node, for the renderer. Derived from the compiler's ROLE, so
/// a new process role shows up as "process" rather than as a lie.
fn node_kind_of(role : String) -> String {
  match role {
    "broker" => "topic"
    "source-runner" => "source"
    "transform-runner" => "transform"
    "sink-runner" => "sink"
    _ => "process"
  }
}

///|
/// One node as JSON: the compiler's process, plus the kind.
fn view_node(process : Process) -> Json {
  let node : Map[String, Json] = {}
  node["id"] = Json::string(process.name)
  node["role"] = Json::string(process.role)
  node["kind"] = Json::string(node_kind_of(process.role))
  node["capability"] = Json::string(process.capability)
  node["detail"] = Json::string(process.detail)
  // can the CURRENT runtime execute it? A graph that draws a process nobody can
  // run is a graph that lies (P2's capability rule)
  node["runnable"] = Json::boolean(capability_runnable(process.capability))
  Json::object(node)
}

///|
/// One edge as JSON.
fn view_edge(from : String, to : String, kind : String) -> Json {
  let edge : Map[String, Json] = {}
  edge["from"] = Json::string(from)
  edge["to"] = Json::string(to)
  edge["kind"] = Json::string(kind)
  Json::object(edge)
}

///|
/// Projects a compiled topology into the console's view model. Pure: same spec
/// and topology, same document, byte for byte.
pub fn view_model(spec : @spec.PipelineSpec, topology : Topology) -> Json {
  let nodes : Array[Json] = []
  for process in topology.processes {
    nodes.push(view_node(process))
  }
  let edges : Array[Json] = []
  let transform_names : Array[String] = []
  for process in topology.processes {
    if process.name.has_prefix("transform-") {
      transform_names.push(process.name)
    }
  }
  // the source's relation to the log: a connector appends into it; a topic
  // source READS it (the relay's first half) and then appends its output
  match spec.source {
    TopicSource(_, _) => {
      edges.push(view_edge("broker", "source-runner", "read"))
      edges.push(view_edge("source-runner", "broker", "append"))
    }
    _ => edges.push(view_edge("source-runner", "broker", "append"))
  }
  // the read path: broker, then the chain in compiler order, then the sink
  let mut previous = "broker"
  for name in transform_names {
    edges.push(view_edge(previous, name, "consume"))
    previous = name
  }
  edges.push(view_edge(previous, "sink-runner", "consume"))
  let doc : Map[String, Json] = {}
  doc["model"] = Json::number(VIEW_MODEL_VERSION.to_double())
  doc["pipeline"] = Json::string(topology.pipeline)
  doc["topic"] = Json::string(topology.topic)
  doc["nodes"] = Json::array(nodes)
  doc["edges"] = Json::array(edges)
  Json::object(doc)
}

///|
/// The view model as text. One stringifier for every host, so "the CLI and the
/// page show the same graph" is a byte comparison instead of an opinion.
pub fn view_model_text(
  spec : @spec.PipelineSpec,
  topology : Topology,
) -> String {
  view_model(spec, topology).stringify(indent=2)
}
