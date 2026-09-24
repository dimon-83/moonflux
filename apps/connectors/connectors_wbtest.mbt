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
test "keyed shaping: split at the first separator, keep the rest in the value" {
  let shaped = text_records_keyed(
    "a:1\nb:2:3\n:emptykey\r\nno-separator\n",
    9L,
    SplitAt(":"),
  )
  assert_eq(shaped.skipped, 1)
  assert_eq(shaped.records.length(), 3)
  assert_eq(@utf8.decode_lossy(shaped.records[0].key), "a")
  assert_eq(value_text(shaped.records[0]), "1")
  assert_eq(@utf8.decode_lossy(shaped.records[1].key), "b")
  assert_eq(value_text(shaped.records[1]), "2:3")
  // a separator at the head is an empty key, not a skipped line
  assert_eq(shaped.records[2].key.length(), 0)
  assert_eq(value_text(shaped.records[2]), "emptykey")
  assert_eq(shaped.records[0].timestamp, 9L)
}

///|
test "keyed shaping: a constant key stamps every record; NoKey is the old rule" {
  let constant = text_records_keyed("x\ny\n", 0L, ConstKey(b"k"))
  assert_eq(constant.skipped, 0)
  assert_eq(constant.records.length(), 2)
  assert_eq(@utf8.decode_lossy(constant.records[0].key), "k")
  assert_eq(@utf8.decode_lossy(constant.records[1].key), "k")
  let plain = text_records_keyed("x\ny\n", 0L, NoKey)
  assert_eq(plain.records.length(), 2)
  assert_eq(plain.records[0].key.length(), 0)
}

///|
test "file source pulls records through the fs adapter" {
  let _ = @fs.mkdirs("/tmp/moonflux_connectors_test")
  let path = "/tmp/moonflux_connectors_test/connector.txt"
  let _ = @fs.write_file(path, b"one\ntwo\n")
  let source = file_source(path, 1L)
  match (source.pull)() {
    Ok(Records(records)) => {
      assert_eq(records.length(), 2)
      assert_eq(value_text(records[0]), "one")
    }
    _ => abort("first pull did not deliver records")
  }
  // the one-shot contract (P19): a file source is not tailed, and its
  // second pull says so instead of replaying the file — a runner loop
  // that conflated "nothing yet" with "fresh data" would append the
  // whole file again and again
  match (source.pull)() {
    Ok(Exhausted) => ()
    Ok(_) => abort("a one-shot source replayed or stayed quiet")
    Err(e) => abort("second pull failed: \{e}")
  }
  // missing file is a structured error, not a panic
  let missing = file_source("/tmp/moonflux_connectors_test/nope.txt", 1L)
  assert_true((missing.pull)() is Err(_))
  let _ = @fs.remove_file(path)
}

///|
test "mqtt urls parse into host, port, topic, and credentials" {
  // core/spec validates the shape before storing one of these; the
  // connector parses the parts
  match parse_mqtt_url("mqtt://broker.local:1884/events/raw") {
    Ok(broker) => {
      assert_eq(broker.host, "broker.local")
      assert_eq(broker.port, 1884)
      assert_eq(broker.topic, "events/raw")
      assert_true(broker.user is None)
    }
    Err(e) => abort("parse failed: \{e}")
  }
  // default port, and credentials before an @
  match parse_mqtt_url("mqtt://user:secret@127.0.0.1/sensors") {
    Ok(broker) => {
      assert_eq(broker.host, "127.0.0.1")
      assert_eq(broker.port, 1883)
      assert_eq(broker.topic, "sensors")
      assert_eq(broker.user, Some("user"))
      assert_eq(broker.password, Some("secret"))
    }
    Err(e) => abort("parse failed: \{e}")
  }
  // refusals: wrong scheme, missing topic, missing host, bad port
  assert_true(parse_mqtt_url("http://x/y") is Err(_))
  assert_true(parse_mqtt_url("mqtt://hostonly") is Err(_))
  assert_true(parse_mqtt_url("mqtt://:1883/topic") is Err(_))
  assert_true(parse_mqtt_url("mqtt://h:notaport/topic") is Err(_))
}

///|
test "mqtt remaining-length varint round-trips its boundaries" {
  // 1 byte, 2 bytes, 3 bytes, 4 bytes — and the largest legal value
  assert_eq(encode_remaining_length(0), b"\x00")
  assert_eq(encode_remaining_length(127), b"\x7f")
  assert_eq(encode_remaining_length(128), b"\x80\x01")
  assert_eq(encode_remaining_length(16383), b"\xff\x7f")
  assert_eq(encode_remaining_length(16384), b"\x80\x80\x01")
  assert_eq(encode_remaining_length(2097151), b"\xff\xff\x7f")
  assert_eq(encode_remaining_length(268435455), b"\xff\xff\xff\x7f")
}

///|
test "mqtt CONNECT carries the protocol name, flags, and credentials" {
  let plain = build_connect("client-1", None, None)
  // fixed header: CONNECT (0x10) + remaining length 0x14 = 20 body
  // bytes (MQTT string 6 + level + flags + keepalive 2 + client id 10)
  assert_eq(plain[0], 0x10)
  assert_eq(plain[1], 0x14)
  // protocol name "MQTT", level 4, clean-session flag, keepalive 30
  assert_eq(plain[1:11], b"\x14\x00\x04MQTT\x04\x02\x00")
  // with credentials the flags gain user|password bits
  let authed = build_connect("client-1", Some("u"), Some("p"))
  assert_eq(authed[9], 0xC2)
}

///|
test "mqtt PUBLISH decodes its topic, payload, and QoS shape" {
  // QoS 0: no packet id between topic and payload
  let body0 = b"\x00\x07sensors\x01\x02\x03"
  match decode_publish(0x30, body0) {
    Ok(publish) => {
      assert_eq(publish.topic, "sensors")
      assert_eq(publish.qos, 0)
      assert_eq(publish.payload, b"\x01\x02\x03")
    }
    Err(e) => abort("qos0 decode failed: \{e}")
  }
  // QoS 1: two packet-id bytes sit before the payload
  let body1 = b"\x00\x03top\x00\x2ahello"
  match decode_publish(0x32, body1) {
    Ok(publish) => {
      assert_eq(publish.topic, "top")
      assert_eq(publish.qos, 1)
      assert_eq(publish.packet_id, 42)
      assert_eq(publish.payload, b"hello")
    }
    Err(e) => abort("qos1 decode failed: \{e}")
  }
  // truncated packets are errors, not panics
  assert_true(decode_publish(0x30, b"\x00") is Err(_))
  assert_true(decode_publish(0x30, b"\x00\x09short") is Err(_))
  assert_true(decode_publish(0x32, b"\x00\x03top\x00") is Err(_))
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
