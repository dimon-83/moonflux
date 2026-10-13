// SPDX-License-Identifier: Apache-2.0
// Host-side HTTP callouts (P30/T115). This is the one transform that leaves
// the process on purpose, so it lives where IO is allowed (apps), not in the
// kernel and not in a guest — a guest has no imports, and that structural
// fact is what keeps "pure operator" a fact rather than a promise.
//
// Determinism is a spec-level CHOICE, not a default:
//
//   live    call the network; the run is as deterministic as the network
//   record  call it and append each exchange to a cassette
//   replay  answer from the cassette, touching no network at all
//
// A spec that omits the mode is refused by the parser, and a replay that
// misses is refused by name — never answered with an empty body. That is the
// whole point of the cassette: the gate can be byte-exact about a pipeline
// that talks to the world, and the same pipeline can be run against the
// world when someone actually wants that.
//
// Credentials: header values of the form `${VAR}` are expanded from the
// node's environment at apply time (the host layer is where "where does the
// credential come from" belongs). A cassette records method, URL, request
// body and response body — NEVER the headers — so a recorded run cannot leak
// the token it used. The gate greps for exactly that.

///|
/// One recorded exchange.
struct CassetteEntry {
  method : String
  url : String
  body : String
  status : Int32
  response : String
}

///|
/// A compiled callout.
struct Callout {
  method : String
  url : String
  body : String
  headers : Array[(String, String)]
  mode : String
  cassette : String
  timeout_ms : Int32
  entries : Array[CassetteEntry]
}

///|
/// Expands `${VAR}` in a header value from the environment. A missing
/// variable is refused: sending the literal text `${OPENAI_API_KEY}` as a
/// bearer token would look like an authentication failure and be a
/// configuration one.
fn expand_env(text : String, path : String) -> Result[String, String] {
  let out = StringBuilder::new()
  let mut rest = text
  while true {
    let open_at = match rest.find("${") {
      Some(at) => at
      None => {
        out.write_string(rest)
        break
      }
    }
    out.write_string(rest[0:open_at].to_owned())
    let after = rest[open_at + 2:rest.length()].to_owned()
    let close_at = match after.find("}") {
      Some(at) => at
      None => return Err("\{path}: unterminated ${...} in \"\{text}\"")
    }
    let name = after[0:close_at].to_owned()
    if name.length() == 0 {
      return Err("\{path}: ${} with no variable name")
    }
    let value = match @env.get_env_var(name) {
      Some(v) => v
      None => return Err("\{path}: environment variable \{name} is not set")
    }
    out.write_string(value)
    rest = after[close_at + 1:after.length()].to_owned()
  }
  Ok(out.to_string())
}

///|
/// Parses one cassette line.
fn parse_cassette_line(line : String) -> Result[CassetteEntry, String] {
  let parsed = match (try? @json.parse(line)) {
    Ok(json) => json
    Err(_) => return Err("cassette line is not JSON")
  }
  let obj = match parsed {
    Object(obj) => obj
    _ => return Err("cassette line is not a JSON object")
  }
  let method = match obj.get("method") {
    Some(String(m)) => m
    _ => return Err("cassette line has no method")
  }
  let url = match obj.get("url") {
    Some(String(u)) => u
    _ => return Err("cassette line has no url")
  }
  let body = match obj.get("body") {
    Some(String(b)) => b
    _ => ""
  }
  let status = match obj.get("status") {
    Some(Number(n)) => n.to_int()
    _ => 200
  }
  let response = match obj.get("response") {
    Some(String(r)) => r
    _ => ""
  }
  Ok(CassetteEntry::{ method, url, body, status, response, })
}

///|
/// Reads a cassette from disk. A missing or unreadable cassette in replay
/// mode is a named refusal: "replay from nothing" would silently be "call
/// nothing and return nothing".
fn load_cassette(path : String) -> Result[Array[CassetteEntry], String] {
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) =>
      return Err(
        "cannot read cassette \{path}: \{e} (record it first, or point the spec at the live network)",
      )
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let entries : Array[CassetteEntry] = []
  for line in text.split("\n") {
    let trimmed = line.trim()
    if trimmed.length() == 0 {
      continue
    }
    match parse_cassette_line(trimmed.to_owned()) {
      Ok(entry) => entries.push(entry)
      Err(e) => return Err("cassette \{path}: \{e}")
    }
  }
  Ok(entries)
}

///|
/// Appends one exchange to the cassette, in the same shape replay reads.
fn append_cassette(
  path : String,
  entry : CassetteEntry,
) -> Result[Unit, String] {
  let line = "{\"method\":" +
    json_quote(entry.method) +
    ",\"url\":" +
    json_quote(entry.url) +
    ",\"body\":" +
    json_quote(entry.body) +
    ",\"status\":" +
    entry.status.to_string() +
    ",\"response\":" +
    json_quote(entry.response) +
    "}"
  // the adapter has no append_file helper: an append handle is how its
  // File API spells it, and a cassette is append-only by design
  let file = match @fs.File::open_append(path) {
    Ok(file) => file
    Err(_) =>
      // the file does not exist yet: create it, then append
      match @fs.File::open_write_or_create(path) {
        Ok(file) => file
        Err(e) => return Err("cannot open cassette \{path}: \{e}")
      }
  }
  let bytes = @utf8.encode(line + "\n")
  let written = match file.write_all(bytes) {
    Ok(n) => n
    Err(e) => {
      let _ = file.close()
      return Err("cannot write cassette \{path}: \{e}")
    }
  }
  let _ = file.flush()
  let _ = file.close()
  if written != bytes.length() {
    return Err(
      "cassette \{path}: short write (\{written} of \{bytes.length()} bytes)",
    )
  }
  Ok(())
}

///|
/// A JSON string literal for the cassette line.
fn json_quote(text : String) -> String {
  let out = StringBuilder::new()
  out.write_string("\"")
  for ch in text {
    match ch {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => out.write_char(ch)
    }
  }
  out.write_string("\"")
  out.to_string()
}

///|
/// Compiles a callout: expands headers, loads the cassette when replaying.
fn compile_callout(c : @spec.CalloutSpec) -> Result[Callout, String] {
  let headers : Array[(String, String)] = []
  for pair in c.headers {
    let value = match expand_env(pair.1, "callout header \{pair.0}") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    headers.push((pair.0, value))
  }
  let entries = match c.mode {
    "replay" =>
      match load_cassette(c.cassette) {
        Ok(entries) => entries
        Err(e) => return Err(e)
      }
    _ => []
  }
  Ok(Callout::{
    method: c.method,
    url: c.url,
    body: c.body,
    headers,
    mode: c.mode,
    cassette: c.cassette,
    timeout_ms: c.timeout_ms,
    entries,
  })
}

///|
/// Reads one scalar field out of a record's value. The host has no fuel
/// budget, so this uses the JSON parser rather than the guests' scanned
/// reader: correctness first, and the cost is the host's.
fn json_field_text(value : Bytes, field : String) -> Result[String, String] {
  let text = @utf8.decode_lossy(value[0:value.length()])
  let parsed = match (try? @json.parse(text)) {
    Ok(json) => json
    Err(_) => return Err("record value is not JSON, so \{field} cannot be read")
  }
  let obj = match parsed {
    Object(obj) => obj
    _ => return Err("record value is not a JSON object")
  }
  match obj.get(field) {
    Some(String(s)) => Ok(s)
    Some(Number(d)) => {
      let n = d.to_int64()
      if n.to_double() == d {
        Ok(n.to_string())
      } else {
        Ok(d.to_string())
      }
    }
    Some(True) => Ok("true")
    Some(False) => Ok("false")
    Some(_) => Err("template field \{field} is not a scalar")
    None => Err("template field \{field} is missing from the record")
  }
}

///|
/// Substitutes `{field}` and `{value}` in a template from the record's value.
/// A missing field is refused: a URL built from a field the record does not
/// have would address an endpoint nobody asked for.
fn fill_template(template : String, value : Bytes) -> Result[String, String] {
  let out = StringBuilder::new()
  let mut rest = template
  while true {
    let open_at = match rest.find("{") {
      Some(at) => at
      None => {
        out.write_string(rest)
        break
      }
    }
    let after = rest[open_at + 1:rest.length()].to_owned()
    let close_at = match after.find("}") {
      Some(at) => at
      None => {
        // no closing brace at all: the rest is literal text (a JSON body
        // may legitimately end in an unmatched brace? no — but refusing
        // here would make an object template unusable, so treat it as text
        // and let the peer judge the request)
        out.write_string(rest)
        break
      }
    }
    let name = after[0:close_at].to_owned()
    // a placeholder is `{identifier}`. Anything else is LITERAL text: a JSON
    // body starts with `{`, and a scanner that jumps to the first `}` turns
    // `{"model":"{model}"}` into the nonsense field `"model":"{model`
    // (measured while gating the POST leg).
    if !is_placeholder_name(name) {
      out.write_string(rest[0:open_at + 1].to_owned())
      rest = after
      continue
    }
    out.write_string(rest[0:open_at].to_owned())
    if name == "value" {
      out.write_string(@utf8.decode_lossy(value[0:value.length()]))
    } else {
      match json_field_text(value, name) {
        Ok(text) => out.write_string(text)
        Err(e) => return Err(e)
      }
    }
    rest = after[close_at + 1:after.length()].to_owned()
  }
  Ok(out.to_string())
}

///|
/// True when a brace body is a placeholder name: `[A-Za-z_][A-Za-z0-9_]*`.
fn is_placeholder_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for i, ch in name {
    let c = ch
    let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    let digit = c >= '0' && c <= '9'
    if i == 0 && !letter {
      return false
    }
    if !letter && !digit {
      return false
    }
  }
  true
}

///|
/// Builds a request with headers, `Connection: close`, and a JSON content
/// type for bodies. Separate from the connector helper because the connector
/// sends no headers and its byte shape is asserted by its own tests.
fn build_callout_request(
  method : String,
  host : String,
  port : Int32,
  path : String,
  body : Bytes,
  headers : Array[(String, String)],
) -> Bytes {
  let sb = StringBuilder::new()
  sb.write_string("\{method} \{path} HTTP/1.1\r\n")
  if port == 80 {
    sb.write_string("Host: \{host}\r\n")
  } else {
    sb.write_string("Host: \{host}:\{port}\r\n")
  }
  sb.write_string("Connection: close\r\n")
  if method == "POST" {
    sb.write_string("Content-Type: application/json\r\n")
    sb.write_string("Content-Length: \{body.length()}\r\n")
  }
  for header in headers {
    sb.write_string("\{header.0}: \{header.1}\r\n")
  }
  sb.write_string("\r\n")
  let head_text = sb.to_string()
  let head = @utf8.encode(head_text[0:head_text.length()])
  let out = Buffer::Buffer()
  out.write_bytes(head[0:head.length()])
  if method == "POST" {
    out.write_bytes(body[0:body.length()])
  }
  out.to_bytes()
}

///|
/// One live exchange WITH a deadline and a response cap. The connector's
/// helper reads to EOF with no timeout because it is used by tests and
/// short-lived sources; an outbound call from a transform is exactly the
/// case the repo's "outbound calls must have a deadline" rule is about.
fn live_exchange(
  method : String,
  url : String,
  body : Bytes,
  headers : Array[(String, String)],
  timeout_ms : Int32,
) -> Result[(Int32, Bytes), String] {
  let (host, port, path) = match @connectors.parse_http_url(url) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{host}:\{port}: \{e}")
  }
  match stream.set_recv_timeout_ms(timeout_ms) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("set timeout: \{e}")
    }
  }
  let request = build_callout_request(method, host, port, path, body, headers)
  match stream.send_all(request) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("send: \{e}")
    }
  }
  let out = Buffer::Buffer()
  let cap = @protocol.MAX_RECORD_BYTES
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  while true {
    match stream.recv(chunk, 65536) {
      Ok(0) => break
      Ok(n) => {
        if out.length() + n > cap {
          let _ = stream.close()
          return Err("response exceeds the record size cap (\{cap} bytes)")
        }
        let part = Bytes::from_fixedarray(chunk, len=n)
        out.write_bytes(part[0:n])
      }
      Err(e) => {
        let _ = stream.close()
        return Err("recv: \{e}")
      }
    }
  }
  let _ = stream.close()
  let (status, response_body) = match
    @connectors.parse_http_response(out.to_bytes()) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  Ok((status, response_body))
}

///|
/// Runs the callout over a batch. Replay never touches the network; record
/// writes what it saw; live is live.
fn Callout::apply(
  self : Callout,
  records : Array[@protocol.Record],
) -> Result[Array[@protocol.Record], String] {
  let out : Array[@protocol.Record] = []
  for r in records {
    let url = match fill_template(self.url, r.value) {
      Ok(url) => url
      Err(e) => return Err(e)
    }
    let body = match fill_template(self.body, r.value) {
      Ok(body) => body
      Err(e) => return Err(e)
    }
    let method = self.method
    let (status, response) = if self.mode == "replay" {
      let mut found : CassetteEntry? = None
      for entry in self.entries {
        if entry.method == method && entry.url == url && entry.body == body {
          found = Some(entry)
          break
        }
      }
      match found {
        Some(entry) => (entry.status, @utf8.encode(entry.response))
        None =>
          return Err(
            "no cassette entry for \{method} \{url} (recorded: \{self.entries.length()} exchange(s); re-record or choose live)",
          )
      }
    } else {
      let body_bytes = if method == "POST" { @utf8.encode(body) } else { b"" }
      let (status, response) = match
        live_exchange(method, url, body_bytes, self.headers, self.timeout_ms) {
        Ok(pair) => pair
        Err(e) => return Err(e)
      }
      if self.mode == "record" {
        match
          append_cassette(self.cassette, CassetteEntry::{
            method,
            url,
            body,
            status,
            response: @utf8.decode_lossy(response[0:response.length()]),
          }) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      (status, response)
    }
    if status < 200 || status >= 300 {
      return Err("\{method} \{url} answered HTTP \{status}")
    }
    out.push(@protocol.Record::{
      timestamp: r.timestamp,
      key: r.key,
      value: response,
      headers: r.headers,
    })
  }
  Ok(out)
}
