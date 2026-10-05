// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the editor kernel's function-set surface (P27).
// These run in the ordinary `moon test` suites: the request builders
// and reply decoders are exactly the bytes the browser session will
// speak, so pinning them here is what makes the browser phase of the
// gate a UI exercise instead of a protocol experiment.

///|
test "abi: the page's expected kernel version" {
  assert_eq(mf_editor_abi_version(), 2)
}

///|
test "build_spec: an expr transform carries its function-set reference" {
  let graph = "{\"name\":\"demo\",\"topic\":\"t\",\"source\":{\"type\":\"stdin\"},\"transforms\":[{\"kind\":\"expr\",\"expr\":\"shout(value)\",\"functions\":\"textkit\"}],\"sink\":{\"type\":\"stdout\"}}"
  let spec = mf_editor_build_spec(graph)
  assert_true(!spec.contains("error"))
  let doc = @json.parse(spec[0:spec.length()])
  let functions = match doc {
    Object(root) =>
      match root.get("spec") {
        Some(Object(spec_obj)) =>
          match spec_obj.get("transforms") {
            Some(Array(transforms)) =>
              match transforms[0] {
                Object(t) => t.get("functions")
                _ => None
              }
            _ => None
          }
        _ => None
      }
    _ => None
  }
  assert_eq(functions, Some(Json::string("textkit")))
  // and the same document passes the spec parser the CLI uses
  let report = mf_editor_validate(spec)
  assert_true(report.contains("\"ok\":true"))
}

///|
test "build_spec: a reference rides expr transforms only" {
  let wasm_graph = "{\"name\":\"demo\",\"topic\":\"t\",\"source\":{\"type\":\"stdin\"},\"transforms\":[{\"kind\":\"wasm\",\"module\":\"ops/x.wasm\",\"functions\":\"textkit\"}],\"sink\":{\"type\":\"stdout\"}}"
  assert_true(
    mf_editor_build_spec(wasm_graph).contains(
      "only an expr transform can reference a function set",
    ),
  )
  let bad_graph = "{\"name\":\"demo\",\"topic\":\"t\",\"source\":{\"type\":\"stdin\"},\"transforms\":[{\"kind\":\"expr\",\"expr\":\"f(value)\",\"functions\":7}],\"sink\":{\"type\":\"stdout\"}}"
  assert_true(
    mf_editor_build_spec(bad_graph).contains(
      "functions must name a function set",
    ),
  )
}

///|
test "build_spec: an empty reference is absent, not empty" {
  let graph = "{\"name\":\"demo\",\"topic\":\"t\",\"source\":{\"type\":\"stdin\"},\"transforms\":[{\"kind\":\"expr\",\"expr\":\"upper(value)\",\"functions\":\"\"}],\"sink\":{\"type\":\"stdout\"}}"
  let spec = mf_editor_build_spec(graph)
  assert_true(!spec.contains("functions"))
}

///|
test "build_function_set: the form becomes the asset document" {
  let form = "{\"name\":\"textkit\",\"functions\":[{\"name\":\"shout\",\"params\":[\"x\"],\"body\":\"upper(x) + \\\"!\\\"\",\"description\":\"\"}]}"
  let built = mf_editor_build_function_set(form)
  assert_true(built.contains("\"ok\":true"))
  // the asset string parses, keeps the mbel JSON v1 fields, and drops
  // the empty description instead of carrying a field that says nothing
  let envelope = @json.parse(built[0:built.length()])
  let asset_text = match envelope {
    Object(root) =>
      match root.get("asset") {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
  assert_true(asset_text.length() > 0)
  let asset = @json.parse(asset_text[0:asset_text.length()])
  match asset {
    Object(doc) => {
      assert_eq(doc.get("name"), Some(Json::string("textkit")))
      match doc.get("functions") {
        Some(Array(fns)) =>
          match fns[0] {
            Object(f) => {
              assert_eq(f.get("name"), Some(Json::string("shout")))
              assert_eq(f.get("body"), Some(Json::string("upper(x) + \"!\"")))
              assert_true(f.get("description") is None)
            }
            _ => assert_true(false)
          }
        _ => assert_true(false)
      }
    }
    _ => assert_true(false)
  }
}

///|
test "build_function_set: shape refusals" {
  // name whitelist is the project's one rule (core/spec), reused
  assert_true(
    mf_editor_build_function_set(
      "{\"name\":\"BAD NAME\",\"functions\":[{\"name\":\"f\",\"params\":[],\"body\":\"1\"}]}",
    ).contains("invalid set name"),
  )
  assert_true(
    mf_editor_build_function_set("{\"name\":\"ok\",\"functions\":[]}").contains(
      "at least one function",
    ),
  )
  assert_true(
    mf_editor_build_function_set(
      "{\"name\":\"ok\",\"functions\":[{\"name\":\"f\",\"params\":[],\"body\":\"\"}]}",
    ).contains("needs a body"),
  )
  assert_true(
    mf_editor_build_function_set(
      "{\"name\":\"ok\",\"functions\":[{\"name\":\"f\",\"params\":[7],\"body\":\"1\"}]}",
    ).contains("params must be strings"),
  )
}

///|
test "session: the function-set verbs speak the protocol's commands" {
  let list = mf_editor_function_set_list()
  assert_eq(list[4].to_int(), @client.CMD_FUNCTION_SET_LIST)
  assert_eq(list.length(), 13)
  let asset = "{\"name\":\"textkit\",\"functions\":[]}"
  let create = mf_editor_function_set_create(asset)
  assert_eq(create[4].to_int(), @client.CMD_FUNCTION_SET_CREATE)
  let create_payload = create[13:create.length()].to_owned()
  assert_eq(
    @utf8.decode_lossy(create_payload[0:create_payload.length()]),
    asset,
  )
  let del = mf_editor_function_set_delete("textkit")
  assert_eq(del[4].to_int(), @client.CMD_FUNCTION_SET_DELETE)
  let del_payload = del[13:del.length()].to_owned()
  assert_eq(@utf8.decode_lossy(del_payload[0:del_payload.length()]), "textkit")
}

///|
test "feed: a LIST reply arrives as its documents" {
  let payload = @utf8.encode(
    "[{\"name\":\"textkit\",\"revision\":3,\"functions\":[]}]",
  )
  let reply = frame(@client.CMD_OK, 9, payload)
  let decoded = mf_editor_feed(reply)
  assert_true(decoded.contains("\"kind\":\"function-sets\""))
  assert_true(decoded.contains("\"name\":\"textkit\""))
  assert_true(decoded.contains("\"revision\":3"))
}

///|
test "feed: a CREATE reply carries the binding facts" {
  let payload = @utf8.encode(
    "{\"name\":\"textkit\",\"revision\":1,\"created\":true}",
  )
  let reply = frame(@client.CMD_OK, 10, payload)
  let decoded = mf_editor_feed(reply)
  assert_true(decoded.contains("\"kind\":\"function-set\""))
  assert_true(decoded.contains("\"created\":true"))
  assert_true(decoded.contains("\"revision\":1"))
  assert_true(!decoded.contains("pipeline"))
}

///|
test "feed: a long LIST reply is not mistaken for an apply reply" {
  // the applied-reply probe reads ulebs, and a JSON array's leading '['
  // (91) passes its length bound when the payload is long enough — the
  // first live LIST reply was longer than the fixture above and got
  // mis-read as `deployed pipeline "{\"name\":…" (real-page catch, P27)
  let long_set = "{\"name\":\"a-set-with-a-long-name\",\"revision\":1,\"functions\":[{\"name\":\"shout\",\"params\":[\"x\"],\"body\":\"upper(x) + \\\"!\\\"\",\"description\":\"the editor's gate function\"}]}"
  let payload = @utf8.encode("[" + long_set + "]")
  assert_true(payload.length() > 91)
  let decoded = mf_editor_feed(frame(@client.CMD_OK, 14, payload))
  assert_true(decoded.contains("\"kind\":\"function-sets\""))
  assert_true(!decoded.contains("pipeline"))
}

///|
test "feed: records and empty OKs keep their shapes" {
  // a fetch reply decodes as records (the pre-P27 path, unchanged)
  let records = @protocol.encode_frame(0L, [
    @protocol.Record::{ timestamp: 0L, key: b"", value: b"hello", headers: [], },
  ])
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_be(1)
  buf.write_uint_be(records.length().reinterpret_as_uint())
  buf.write_bytes(records[0:records.length()])
  let decoded = mf_editor_feed(frame(@client.CMD_OK, 11, buf.to_bytes()))
  assert_true(decoded.contains("\"kind\":\"records\""))
  // an empty OK (delete) is a plain ok, not a mis-read of something
  assert_true(
    mf_editor_feed(frame(@client.CMD_OK, 12, b"")).contains("\"kind\":\"ok\""),
  )
  // an error stays an error
  let err = mf_editor_feed(frame(@client.CMD_ERR, 13, @utf8.encode("boom")))
  assert_true(err.contains("\"kind\":\"error\""))
}
