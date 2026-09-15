// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for apps/connectors — URL/request/response parsing
// and the shared text-shaper. Live HTTP round trips are covered by
// scripts/e2e-p1-connectors.sh against a real fixture server.

///|
test "url parsing: default port, explicit port, path" {
  assert_eq(
    parse_http_url("http://example.com/a/b"),
    Ok(("example.com", 80, "/a/b")),
  )
  assert_eq(
    parse_http_url("http://127.0.0.1:8080"),
    Ok(("127.0.0.1", 8080, "/")),
  )
  assert_eq(
    parse_http_url("http://127.0.0.1:18080/data?x=1"),
    Ok(("127.0.0.1", 18080, "/data?x=1")),
  )
  assert_true(parse_http_url("https://example.com/") is Err(_))
  assert_true(parse_http_url("http://example.com:abc/") is Err(_))
  assert_true(parse_http_url("http://") is Err(_))
}

///|
test "request building: GET and POST shapes" {
  let get = @utf8.decode_lossy(
    parse_view(build_http_request("GET", "h.example", 80, "/x", b"")),
  )
  assert_true(get.has_prefix("GET /x HTTP/1.1\r\n"))
  assert_true(get.contains("Host: h.example\r\n"))
  assert_true(get.has_suffix("\r\n\r\n"))
  let post = @utf8.decode_lossy(
    parse_view(
      build_http_request("POST", "h.example", 8080, "/sink", b"a\nb\n"),
    ),
  )
  assert_true(post.contains("Host: h.example:8080\r\n"))
  assert_true(post.contains("Content-Length: 4\r\n"))
  assert_true(post.has_suffix("\r\n\r\na\nb\n"))
}

///|
test "response parsing: status, body, binary preservation" {
  let response = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab\x00c"
  match parse_http_response(response) {
    Ok((status, body)) => {
      assert_eq(status, 200)
      assert_true(body == b"ab\x00c")
    }
    Err(e) => abort("parse failed: \{e}")
  }
  match parse_http_response(b"HTTP/1.1 404 Not Found\r\n\r\nnope") {
    Ok((status, body)) => {
      assert_eq(status, 404)
      assert_true(body == b"nope")
    }
    Err(e) => abort("parse failed: \{e}")
  }
  assert_true(parse_http_response(b"garbage without terminator") is Err(_))
  assert_true(parse_http_response(b"HTTP/1.1 two-hundred OK\r\n\r\n") is Err(_))
}

///|
test "text records: CRLF trimmed, blank lines dropped" {
  let records = records_from_text("alpha\r\n\r\nbravo\ncharlie\n", 7L)
  assert_eq(records.length(), 3)
  assert_eq(value_text(records[0]), "alpha")
  assert_eq(value_text(records[1]), "bravo")
  assert_eq(value_text(records[2]), "charlie")
  assert_eq(records[0].timestamp, 7L)
}

///|
test "file source pulls records through the fs adapter" {
  let _ = @fs.mkdirs("/tmp/moonflux_connectors_test")
  let path = "/tmp/moonflux_connectors_test/connector.txt"
  let _ = @fs.write_file(path, b"one\ntwo\n")
  let source = file_source(path, 1L)
  match (source.pull)() {
    Ok(records) => {
      assert_eq(records.length(), 2)
      assert_eq(value_text(records[0]), "one")
    }
    Err(e) => abort("pull failed: \{e}")
  }
  // missing file is a structured error, not a panic
  let missing = file_source("/tmp/moonflux_connectors_test/nope.txt", 1L)
  assert_true((missing.pull)() is Err(_))
  let _ = @fs.remove_file(path)
}

///|
test "stdout sink renders one line per value" {
  // exercised via the shared renderer: the sink prints through
  // println; here we pin the value shaping it relies on
  let records = records_from_text("x\ny\n", 0L)
  assert_eq(value_text(records[1]), "y")
}

///|
fn parse_view(bytes : Bytes) -> BytesView {
  bytes[0:bytes.length()]
}
