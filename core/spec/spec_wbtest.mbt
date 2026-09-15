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
      assert_true(spec.transforms[0] is ExprTransform(".value | upper()"))
    }
    Err(errors) => abort("transform spec rejected: \{errors}")
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
  let text = "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"mqtt\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"kafka\"}}}"
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
