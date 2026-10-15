// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/spec — validation rules pinned one by one.

///|
const VALID_MINIMAL : String = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"events.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}"

///|
test "valid minimal spec parses with all fields" {
  match parse_spec(VALID_MINIMAL) {
    Ok(spec) => {
      assert_eq(spec.metadata_name, "file-to-stdout")
      assert_true(spec.source is FileSource("events.txt"))
      assert_true(spec.transforms.is_empty())
      assert_eq(spec.topic.name, "events")
      assert_true(spec.sink is StdoutSink)
    }
    Err(errors) => abort("valid spec rejected: \{errors}")
  }
}

///|
test "spec with one expr transform validates (execution is P1)" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\".value | upper()\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(text) {
    Ok(spec) => {
      assert_eq(spec.transforms.length(), 1)
      assert_true(spec.transforms[0] is ExprTransform(".value | upper()", ""))
    }
    Err(errors) => abort("transform spec rejected: \{errors}")
  }
}

///|
test "an expr transform may reference a function set" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\"shout(value)\",\"functions\":\"pricing\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(text) {
    Ok(spec) =>
      assert_true(
        spec.transforms[0] is ExprTransform("shout(value)", "pricing"),
      )
    Err(errors) => abort("transform spec rejected: \{errors}")
  }
  // an empty name is a mistake, not a shorthand: the reference must
  // resolve, and resolution is what apply checks
  let empty = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\"value\",\"functions\":\"\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(empty) {
    Err(errors) => assert_eq(errors[0].code, "bad-value")
    Ok(_) => abort("empty functions name accepted")
  }
  // a non-string is a type error, reported at its own path
  let wrong_type = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\"value\",\"functions\":42}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(wrong_type) {
    Err(errors) => assert_eq(errors[0].code, "bad-type")
    Ok(_) => abort("non-string functions accepted")
  }
}

///|
test "wrong apiVersion and kind reported together" {
  let text = "{\"apiVersion\":\"moonflux.io/v1\",\"kind\":\"Thing\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(text) {
    Err(errors) => {
      assert_eq(errors.length(), 2)
      assert_eq(errors[0].code, "bad-api-version")
      assert_eq(errors[1].code, "bad-kind")
    }
    Ok(_) => abort("expected errors")
  }
}

///|
test "invalid metadata name rejected with rule message" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"Bad_Name\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(text) {
    Err(errors) => assert_eq(errors[0].code, "bad-name")
    Ok(_) => abort("expected errors")
  }
}

///|
test "unknown source type and unknown sink type collected together" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"amqp\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"kinesis\"}}}"
  match parse_spec(text) {
    Err(errors) => {
      assert_eq(errors.length(), 2)
      assert_eq(errors[0].path, "$.spec.source.type")
      assert_eq(errors[1].path, "$.spec.sink.type")
    }
    Ok(_) => abort("expected errors")
  }
}

///|
test "mqtt sources and sinks parse, and their urls are validated at apply time" {
  // a valid pair round-trips into the spec
  let good = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:1884/sensors\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:1884/out\"}}}"
  match parse_spec(good) {
    Ok(spec) => {
      assert_true(spec.source is MqttSource(_))
      assert_true(spec.sink is MqttSink(_))
    }
    Err(errors) => abort("valid mqtt spec rejected: \{errors}")
  }
  // a url the connector would refuse to open is refused here, where the
  // failure is cheap
  let no_topic = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"mqtt\",\"url\":\"mqtt://127.0.0.1:1884\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(no_topic) {
    Err(errors) => assert_eq(errors[0].path, "$.spec.source.url")
    Ok(_) => abort("topicless mqtt url accepted")
  }
  let no_url = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"mqtt\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(no_url) {
    Err(errors) => assert_eq(errors[0].path, "$.spec.source.url")
    Ok(_) => abort("mqtt source without a url accepted")
  }
}

///|
test "unknown fields rejected at every level" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\",\"bogus\":1},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\",\"extra\":true},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"},\"wat\":1},\"top\":2}"
  match parse_spec(text) {
    Err(errors) => {
      let mut saw_meta = false
      let mut saw_source = false
      let mut saw_spec = false
      for e in errors {
        if e.path == "$.metadata.bogus" {
          saw_meta = true
        }
        if e.path == "$.spec.source.extra" {
          saw_source = true
        }
        if e.path == "$.spec.wat" {
          saw_spec = true
        }
      }
      assert_true(saw_meta && saw_source && saw_spec)
    }
    Ok(_) => abort("expected errors")
  }
}

///|
test "missing required sections each produce one error" {
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\"}"
  match parse_spec(text) {
    Err(errors) => {
      // metadata + spec both missing
      assert_eq(errors.length(), 2)
      assert_eq(errors[0].path, "$.metadata")
      assert_eq(errors[1].path, "$.spec")
    }
    Ok(_) => abort("expected errors")
  }
}

///|
test "non-object document rejected" {
  match parse_spec("[]") {
    Err(errors) => assert_eq(errors[0].code, "bad-type")
    Ok(_) => abort("expected errors")
  }
  match parse_spec("not json") {
    Err(errors) => assert_eq(errors[0].code, "invalid-json")
    Ok(_) => abort("expected errors")
  }
}

///|
test "dns label boundary cases" {
  assert_true(is_dns_label("a"))
  assert_true(is_dns_label("abc-123"))
  assert_false(is_dns_label("-abc"))
  assert_false(is_dns_label("abc-"))
  assert_false(is_dns_label("Abc"))
  assert_false(is_dns_label(""))
  assert_false(
    is_dns_label(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ),
  )
}

///|
test "topic name charset pinned" {
  assert_true(valid_topic_name("events.prod_1"))
  assert_false(valid_topic_name("../escape"))
  assert_false(valid_topic_name("Ümlaut"))
  assert_false(valid_topic_name(""))
}

///|
test "an http source takes an optional poll interval" {
  // absent or 0 keeps the one-shot P1 behavior; positive makes a poller
  let one_shot = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"http://h/p\"},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(one_shot) {
    Ok(spec) => assert_true(spec.source is HttpSource("http://h/p", 0L, [], ""))
    Err(errors) => abort("one-shot http source rejected: \{errors}")
  }
  let polled = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"http://h/p\",\"interval_ms\":250},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(polled) {
    Ok(spec) =>
      assert_true(spec.source is HttpSource("http://h/p", 250L, [], ""))
    Err(errors) => abort("polled http source rejected: \{errors}")
  }
  // a negative or non-numeric interval is a named rejection, not a clamp
  let negative = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"http://h/p\",\"interval_ms\":-1},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(negative) {
    Ok(_) => abort("a negative interval should be rejected")
    Err(errors) =>
      assert_true(errors.any(fn(e) { e.path == "$.spec.source.interval_ms" }))
  }
  let textual = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"http://h/p\",\"interval_ms\":\"soon\"},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(textual) {
    Ok(_) => abort("a non-numeric interval should be rejected")
    Err(errors) =>
      assert_true(errors.any(fn(e) { e.path == "$.spec.source.interval_ms" }))
  }
}

///|
test "a pipeline may declare where its state lives, and only sanely" {
  let base = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}STATE}}"
  let with_state = ",\"state\":{\"topic\":\"counters\"}"
  // absent: no state, and a stateless spec stays exactly as it was
  match parse_spec(base.replace(old="STATE", new="")) {
    Ok(spec) => assert_true(spec.state is None)
    Err(errors) => abort("a stateless spec was rejected: \{errors}")
  }
  // present: the topic is parsed as written
  match parse_spec(base.replace(old="STATE", new=with_state)) {
    Ok(spec) => assert_true(spec.state is Some("counters"))
    Err(errors) => abort("a state topic was rejected: \{errors}")
  }
  // a state topic equal to the data topic is a ring, not a configuration
  match
    parse_spec(
      base.replace(old="STATE", new=",\"state\":{\"topic\":\"events\"}"),
    ) {
    Ok(_) => abort("the data topic was accepted as the state topic")
    Err(errors) =>
      assert_true(
        errors.any(fn(e) {
          e.path == "$.spec.state.topic" && e.code == "bad-value"
        }),
      )
  }
  // an invalid name, an unknown key and a non-object are each rejected
  match
    parse_spec(
      base.replace(old="STATE", new=",\"state\":{\"topic\":\"Bad Name\"}"),
    ) {
    Ok(_) => abort("an invalid state topic name was accepted")
    Err(errors) =>
      assert_true(errors.any(fn(e) { e.path == "$.spec.state.topic" }))
  }
  match
    parse_spec(
      base.replace(
        old="STATE",
        new=",\"state\":{\"topic\":\"c\",\"retention\":1}",
      ),
    ) {
    Ok(_) => abort("an unknown state key was accepted")
    Err(errors) =>
      assert_true(errors.any(fn(e) { e.path == "$.spec.state.retention" }))
  }
  match parse_spec(base.replace(old="STATE", new=",\"state\":\"counters\"")) {
    Ok(_) => abort("a bare string was accepted as state")
    Err(errors) => assert_true(errors.any(fn(e) { e.path == "$.spec.state" }))
  }
}

///|
/// Request headers are part of the source, and the injection guard is the point
/// of validating them at all: a value with CR or LF would end the header block
/// and let the rest be read as a request of the caller's choosing.
test "http source headers parse, and injection is refused" {
  let doc = fn(headers : String) {
    "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\"," +
    "\"metadata\":{\"name\":\"h\"},\"spec\":{\"source\":{\"type\":\"http\"," +
    "\"url\":\"http://h/p\",\"headers\":" +
    headers +
    "}," +
    "\"topic\":{\"name\":\"t\"},\"transforms\":[],\"sink\":{\"type\":\"stdout\"}}}"
  }
  match parse_spec(doc("{\"Accept-Profile\":\"ia_csc\",\"X-Trace\":\"abc\"}")) {
    Ok(spec) =>
      match spec.source {
        HttpSource(_, _, headers, _) => {
          assert_eq(headers.length(), 2)
          // sorted by name: an object's iteration order must not reach the wire
          assert_eq(headers[0], ("Accept-Profile", "ia_csc"))
          assert_eq(headers[1], ("X-Trace", "abc"))
        }
        _ => abort("expected an http source")
      }
    Err(errors) => abort("headers should have parsed: \{errors}")
  }
  for
    bad in [
      "{\"Accept-Profile\":\"a\\r\\nX-Evil: 1\"}", "{\"Accept-Profile\":\"a\\nb\"}",
      "{\"Bad Name\":\"x\"}", "{\"\":\"x\"}", "{\"X\":1}",
    ] {
    match parse_spec(doc(bad)) {
      Ok(_) => abort("headers \{bad} should have been refused")
      Err(_) => ()
    }
  }
}

///|
/// https needs an explicit trust anchor, refused at VALIDATION time with a
/// message that names the key — measured need: the real feed is https, and the
/// http source's TLS verifies with whatever CA the spec names (no implicit
/// system store, so an empty one can only fail later with an OpenSSL sentence).
test "https source needs a ca, and carries it" {
  let doc = fn(source : String) {
    "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\"," +
    "\"metadata\":{\"name\":\"h\"},\"spec\":{\"source\":" +
    source +
    "," +
    "\"topic\":{\"name\":\"t\"},\"transforms\":[],\"sink\":{\"type\":\"stdout\"}}}"
  }
  match
    parse_spec(
      doc("{\"type\":\"http\",\"url\":\"https://h/p\",\"ca\":\"/tmp/ca.pem\"}"),
    ) {
    Ok(spec) =>
      match spec.source {
        HttpSource(url, _, _, ca) => {
          assert_eq(url, "https://h/p")
          assert_eq(ca, "/tmp/ca.pem")
        }
        _ => abort("expected an http source")
      }
    Err(errors) => abort("https with a ca should have parsed: \{errors}")
  }
  match parse_spec(doc("{\"type\":\"http\",\"url\":\"https://h/p\"}")) {
    Ok(_) => abort("https without a ca must be refused")
    Err(errors) => {
      let text = "\{errors}"
      assert_true(text.contains("https sources need ca"))
    }
  }
  // a plain-http source still parses with no ca at all
  match parse_spec(doc("{\"type\":\"http\",\"url\":\"http://h/p\"}")) {
    Ok(_) => ()
    Err(errors) => abort("http without ca should parse: \{errors}")
  }
}

///|
/// The http SINK is the alert path: a real webhook is https and authenticates
/// with a header, so the sink gets the same headers/ca treatment as the source —
/// and the same refusal when https has no trust anchor.
test "https sink needs a ca, and carries headers" {
  let doc = fn(sink : String) {
    "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\"," +
    "\"metadata\":{\"name\":\"s\"},\"spec\":{\"source\":{\"type\":\"stdin\"}," +
    "\"topic\":{\"name\":\"t\"},\"transforms\":[],\"sink\":" +
    sink +
    "}}"
  }
  match
    parse_spec(
      doc(
        "{\"type\":\"http\",\"url\":\"https://hook.example/x\"," +
        "\"headers\":{\"Authorization\":\"Bearer t\"},\"ca\":\"/etc/ca.pem\"}",
      ),
    ) {
    Ok(spec) =>
      match spec.sink {
        HttpSink(url, headers, ca) => {
          assert_eq(url, "https://hook.example/x")
          assert_eq(ca, "/etc/ca.pem")
          assert_eq(headers.length(), 1)
          assert_eq(headers[0], ("Authorization", "Bearer t"))
        }
        _ => abort("expected an http sink")
      }
    Err(errors) => abort("https sink with a ca should have parsed: \{errors}")
  }
  match
    parse_spec(doc("{\"type\":\"http\",\"url\":\"https://hook.example/x\"}")) {
    Ok(_) => abort("an https sink without a ca must be refused")
    Err(errors) => assert_true("\{errors}".contains("https sinks need ca"))
  }
  // http sinks are unchanged: no ca required
  match
    parse_spec(doc("{\"type\":\"http\",\"url\":\"http://hook.example/x\"}")) {
    Ok(_) => ()
    Err(errors) => abort("a plain http sink should parse: \{errors}")
  }
  // a sink header carrying a newline is refused like a source header
  match
    parse_spec(
      doc(
        "{\"type\":\"http\",\"url\":\"http://h/x\"," +
        "\"headers\":{\"X\":\"a\\r\\nb\"}}",
      ),
    ) {
    Ok(_) => abort("a CR/LF sink header must be refused")
    Err(_) => ()
  }
}

///|
/// A topic source that starts from the beginning, feeding a sink with an
/// EXTERNAL side effect, re-delivers everything on every restart — a run commits
/// no progress (see TopicSource). The platform can see it, so it says it.
test "replay_warnings: a replay into an external side effect is named" {
  let spec = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"alerts\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"decisions\",\"from\":\"beginning\"},\"transforms\":[],\"topic\":{\"name\":\"decisions\"},\"sink\":{\"type\":\"http\",\"url\":\"http://example.invalid/hook\"}}}"
  match parse_spec(spec) {
    Ok(parsed) => {
      let warnings = replay_warnings(parsed)
      assert_eq(warnings.length(), 1)
      assert_true(warnings[0].contains("EVERY restart"))
      assert_true(warnings[0].contains("HTTP sink"))
    }
    Err(errors) => abort("spec rejected: \{errors}")
  }
}

///|
/// The two ways to NOT have that trap: start at the end, or keep the effect
/// inside the platform. Both must be silent, or the warning becomes noise and
/// operators learn to ignore it.
test "replay_warnings: from the end, or a non-external sink, says nothing" {
  let at_end = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"alerts\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"decisions\",\"from\":\"end\"},\"transforms\":[],\"topic\":{\"name\":\"decisions\"},\"sink\":{\"type\":\"http\",\"url\":\"http://example.invalid/hook\"}}}"
  match parse_spec(at_end) {
    Ok(parsed) => assert_eq(replay_warnings(parsed).length(), 0)
    Err(errors) => abort("spec rejected: \{errors}")
  }
  let internal = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"relay\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"decisions\",\"from\":\"beginning\"},\"transforms\":[],\"topic\":{\"name\":\"decisions\"},\"sink\":{\"type\":\"stdout\"}}}"
  match parse_spec(internal) {
    Ok(parsed) => assert_eq(replay_warnings(parsed).length(), 0)
    Err(errors) => abort("spec rejected: \{errors}")
  }
  // an explicit offset replays too, and it is the same trap for the same reason
  let from_offset = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"alerts\"},\"spec\":{\"source\":{\"type\":\"topic\",\"name\":\"decisions\",\"from\":5},\"transforms\":[],\"topic\":{\"name\":\"decisions\"},\"sink\":{\"type\":\"mqtt\",\"url\":\"mqtt://broker/t\"}}}"
  match parse_spec(from_offset) {
    Ok(parsed) => assert_eq(replay_warnings(parsed).length(), 1)
    Err(errors) => abort("spec rejected: \{errors}")
  }
}

///|
/// One template plus a list of points becomes a task set (P1-1). The JSON body's
/// own braces stay literal — decision 66's rule, reused: only `{identifier}` is a
/// placeholder.
test "expand_points: a template and a fleet become a task set" {
  let text = "{\"template\":{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"{name}\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"https://x/pgrest?node_name=eq.{point}\",\"interval_ms\":20000,\"headers\":{\"Accept-Profile\":\"ia_csc\"}},\"topic\":{\"name\":\"{name}-polls\"},\"transforms\":[],\"sink\":{\"type\":\"callout\",\"mode\":\"live\",\"method\":\"POST\",\"url\":\"https://hook/{point}\",\"body\":\"{\\\"point\\\":\\\"{point}\\\"}\"}}},\"points\":[{ \"name\":\"inlet-cod\",\"point\":\"CN_进水COD\",\"target\":\"worker-a\",\"restart\":\"on-failure\"},{\"name\":\"outlet-nh3\",\"point\":\"CN_出水氨氮\"}]}"
  match expand_points(text) {
    Ok(set) => {
      let json = @json.parse(set[0:set.length()]) catch {
        e => abort("expanded set is not JSON: \{e}")
      }
      let root = match json {
        Object(o) => o
        _ => abort("expanded set is not an object")
      }
      let pipelines = match root.get("pipelines") {
        Some(Array(items)) => items
        _ => abort("no pipelines array")
      }
      assert_eq(pipelines.length(), 2)
      // Read the CONTENT back out of the TREE, not out of the serialized text:
      // JSON escapes non-ASCII, so a `contains` on the document would be testing
      // the serializer's escaping rather than the substitution (measured: exactly
      // how this assertion first failed).
      let first = match pipelines[0] {
        Object(p) => p
        _ => abort("a pipeline is not an object")
      }
      // a task is {pipeline, spec, target, restart} and that `spec` is the whole
      // Pipeline document, so the content lives one level deeper than it looks
      let doc = match first.get("spec") {
        Some(Object(x)) => x
        _ => abort("no spec document")
      }
      let spec = match doc.get("spec") {
        Some(Object(x)) => x
        _ => abort("no spec body")
      }
      let source = match spec.get("source") {
        Some(Object(x)) => x
        _ => abort("no source")
      }
      assert_eq(
        match source.get("url") {
          Some(String(u)) => u
          _ => ""
        },
        "https://x/pgrest?node_name=eq.CN_\u8fdb\u6c34COD",
      )
      // the JSON body's own braces survived as LITERALS, and only `{point}` was
      // replaced inside it
      let sink = match spec.get("sink") {
        Some(Object(x)) => x
        _ => abort("no sink")
      }
      assert_eq(
        match sink.get("body") {
          Some(String(b)) => b
          _ => ""
        },
        "{" + "\"point\":\"CN_\u8fdb\u6c34COD\"}",
      )
      assert_eq(
        match spec.get("topic") {
          Some(Object(t)) =>
            match t.get("name") {
              Some(String(n)) => n
              _ => ""
            }
          _ => ""
        },
        "inlet-cod-polls",
      )
      // the task-level fields ride along, and only where they were given
      assert_true(set.contains("\"pipeline\":\"inlet-cod\""))
      assert_true(set.contains("\"target\":\"worker-a\""))
      assert_true(set.contains("\"restart\":\"on-failure\""))
      assert_true(set.contains("\"topic\":{\"name\":\"outlet-nh3-polls\"}"))
    }
    Err(errors) => abort("a valid fleet was refused: \{errors}")
  }
}

///|
/// Three refusals, each one a mistake that would otherwise reach the cluster:
/// two points wanting one task name (names identify runs), a placeholder nothing
/// supplies (a typo), and a point with no name at all.
test "expand_points: duplicate names, unknown placeholders and nameless points are refused" {
  let base = "\"template\":{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"{name}\"},\"spec\":{\"source\":{\"type\":\"stdout\"}}}"
  match
    expand_points(
      "{" +
      base +
      ",\"points\":[{ \"name\":\"a\",\"point\":\"p\"},{\"name\":\"a\",\"point\":\"q\"}]}",
    ) {
    Ok(_) => abort("a duplicate task name was accepted")
    Err(errors) => assert_eq(errors[0].code, "duplicate")
  }
  match
    expand_points(
      "{\"template\":{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"{name}\",\"x\":\"{ponit}\"},\"spec\":{\"source\":{\"type\":\"stdout\"}}},\"points\":[{ \"name\":\"a\",\"point\":\"p\"}]}",
    ) {
    Ok(_) => abort("an unknown placeholder was accepted")
    Err(errors) => assert_eq(errors[0].code, "unknown-placeholder")
  }
  match expand_points("{" + base + ",\"points\":[{ \"point\":\"p\"}]}") {
    Ok(_) => abort("a point with no task name was accepted")
    Err(errors) => assert_eq(errors[0].code, "missing")
  }
}
