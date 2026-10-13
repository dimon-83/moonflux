// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/pipeline — compile shape, determinism,
// diff semantics.

///|
fn spec(text : String) -> @spec.PipelineSpec {
  match @spec.parse_spec(text) {
    Ok(spec) => spec
    Err(errors) => abort("fixture spec invalid: \{errors}")
  }
}

///|
const SPEC_A : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"a.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
const SPEC_B : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"b.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
const SPEC_T : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"a.txt\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\"upper()\"}],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
test "compile produces broker + source + sink" {
  let t = compile(spec(SPEC_A))
  assert_eq(t.pipeline, "file-to-stdout")
  assert_eq(t.topic, "events")
  assert_eq(t.processes.length(), 3)
  assert_eq(t.processes[0].name, "broker")
  assert_eq(t.processes[1].name, "source-runner")
  assert_eq(t.processes[1].detail, "file source: a.txt")
  assert_eq(t.processes[2].name, "sink-runner")
  assert_true(runnable(t))
}

///|
test "compile is deterministic" {
  assert_eq(compile(spec(SPEC_A)), compile(spec(SPEC_A)))
}

///|
test "transform compiles to an mbel-tagged runner" {
  let t = compile(spec(SPEC_T))
  assert_eq(t.processes.length(), 4)
  assert_eq(t.processes[2].name, "transform-0")
  assert_eq(t.processes[2].capability, "mbel")
  assert_eq(t.processes[2].detail, "expr transform: upper()")
  assert_true(runnable(t))
}

///|
test "diff: full create, no-op, update" {
  let a = compile(spec(SPEC_A))
  let b = compile(spec(SPEC_B))
  // full create: everything added
  let create = diff(None, a)
  assert_eq(create.length(), 3)
  // no-op
  assert_eq(diff(Some(a), a).length(), 0)
  // source path change -> one update, same process set
  let update = diff(Some(a), b)
  assert_eq(update.length(), 1)
  assert_true(
    update[0]
    is Update("source-runner", "file source: a.txt", "file source: b.txt"),
  )
}

///|
const SPEC_W : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"a.txt\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"operators/upper.wasm\"}],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
const SPEC_W_CFG : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"a.txt\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"operators/upper.wasm\",\"config\":{\"mode\":\"identity\"}}],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
test "wasm transform compiles with wasm capability" {
  let t = compile(spec(SPEC_W))
  assert_eq(t.processes.length(), 4)
  assert_eq(t.processes[2].name, "transform-0")
  assert_eq(t.processes[2].capability, "wasm")
  assert_eq(
    t.processes[2].detail,
    "wasm operator: operators/upper.wasm config={}",
  )
  assert_true(runnable(t))
}

///|
test "wasm transform carries its operator config into the plan" {
  let t = compile(spec(SPEC_W_CFG))
  assert_eq(t.processes[2].capability, "wasm")
  assert_eq(
    t.processes[2].detail,
    "wasm operator: operators/upper.wasm config={\"mode\":\"identity\"}",
  )
  assert_true(runnable(t))
}

///|
test "render_diff prints stable human-readable output" {
  let a = compile(spec(SPEC_A))
  let b = compile(spec(SPEC_B))
  let text = render_diff(diff(Some(a), b))
  assert_true(
    text.contains("~ source-runner: file source: a.txt -> file source: b.txt"),
  )
  assert_true(text.contains("diff: 0 to add, 1 to update, 0 to remove"))
}

///|
const SPEC_TOPIC_SOURCE : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"relay\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"events\",\"from\":\"beginning\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
fn nodes_of(model : Json) -> Array[String] {
  let out : Array[String] = []
  match model.value("nodes") {
    Some(Array(items)) =>
      for item in items {
        match item.value("id") {
          Some(String(id)) => out.push(id)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn edges_of(model : Json) -> Array[String] {
  let out : Array[String] = []
  match model.value("edges") {
    Some(Array(items)) =>
      for item in items {
        let from = match item.value("from") {
          Some(String(v)) => v
          _ => "?"
        }
        let to = match item.value("to") {
          Some(String(v)) => v
          _ => "?"
        }
        let kind = match item.value("kind") {
          Some(String(v)) => v
          _ => "?"
        }
        out.push("\{from}->\{to}:\{kind}")
      }
    _ => ()
  }
  out
}

///|
/// The nodes ARE the compiler's processes, in the compiler's order — the
/// view model may not reorder, drop or invent one (that is the whole claim the
/// console rests on).
test "the view model's nodes are the topology's processes" {
  for text in [SPEC_A, SPEC_T, SPEC_TOPIC_SOURCE] {
    let parsed = spec(text)
    let topology = compile(parsed)
    let model = view_model(parsed, topology)
    let ids = nodes_of(model)
    assert_eq(ids.length(), topology.processes.length())
    for i, process in topology.processes {
      assert_eq(ids[i], process.name)
    }
    assert_eq(model.value("model").unwrap(), Json::number(1))
    assert_eq(model.value("pipeline").unwrap(), Json::string(topology.pipeline))
  }
}

///|
/// The edges follow the documented rule: a connector source appends; a topic
/// source reads and appends (the relay); the read path runs broker -> chain ->
/// sink, and an empty chain is broker -> sink.
test "the view model's edges follow the source shape and the chain" {
  let connector = spec(SPEC_A)
  assert_eq(edges_of(view_model(connector, compile(connector))), [
    "source-runner->broker:append", "broker->sink-runner:consume",
  ])
  let with_transform = spec(SPEC_T)
  assert_eq(edges_of(view_model(with_transform, compile(with_transform))), [
    "source-runner->broker:append", "broker->transform-0:consume", "transform-0->sink-runner:consume",
  ])
  let relay = spec(SPEC_TOPIC_SOURCE)
  assert_eq(edges_of(view_model(relay, compile(relay))), [
    "broker->source-runner:read", "source-runner->broker:append", "broker->sink-runner:consume",
  ])
}

///|
/// Determinism, and the text form every host shares.
test "the view model is deterministic and stringifiable" {
  let parsed = spec(SPEC_T)
  let topology = compile(parsed)
  let a = view_model_text(parsed, topology)
  let b = view_model_text(parsed, topology)
  assert_eq(a, b)
  // the text form is `stringify(indent=2)`, so the separator carries a space
  assert_true(a.contains("\"model\": 1"))
  assert_true(a.contains("\"nodes\": ["))
}
