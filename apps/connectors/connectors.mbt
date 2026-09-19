// SPDX-License-Identifier: Apache-2.0
// apps/connectors: Source/Sink framework (P1) — the external read/write
// edge of the data path. P1 ships: file, stdin, and HTTP GET sources;
// stdout and HTTP POST sinks. HTTP is a minimal plain-HTTP/1.1 client
// on top of net-native (the P1 scope cut: no TLS, no redirects, no
// chunked bodies beyond what the fixture needs).
//
// Sources are one-shot pulls: the runner decides cadence (P1 runs a
// single pass per invocation; polling/follow modes are P2+).

///|
/// A data source: one pull yields the records currently available.
pub(all) struct Source {
  name : String
  pull : () -> Result[Array[@protocol.Record], String]
}

///|
/// A data sink: one flush delivers a batch (consumption path).
pub(all) struct Sink {
  name : String
  flush : (Array[@protocol.Record]) -> Result[Unit, String]
}

///|
/// How a text source shapes each line into a record key (P14). `NoKey`
/// is the original behaviour; `ConstKey` stamps every record with the
/// same key; `SplitAt` cuts each line at its **first** separator into
/// (key, value).
pub(all) enum KeyMode {
  NoKey
  ConstKey(Bytes)
  SplitAt(String)
} derive(Eq, Debug)

///|
/// The records a text shaping produced, and how many lines a
/// `SplitAt` mode skipped because they carried no separator.
pub(all) struct ShapedText {
  records : Array[@protocol.Record]
  skipped : Int
} derive(Debug)

///|
/// Splits text into non-empty lines as value-only records with the
/// given timestamps (the shared record-shaping rule of text sources).
pub fn records_from_text(
  text : String,
  timestamp : Int64,
) -> Array[@protocol.Record] {
  text_records_keyed(text, timestamp, NoKey).records
}

///|
/// The shared record-shaping rule of text sources, with the key modes
/// `produce --key / --key-separator` selects. A `SplitAt` line with no
/// separator is **skipped and counted** rather than keyed with the
/// whole line: the operator asked for a key, and inventing one would
/// put the line's text where the key belongs (the reference system's
/// CLI skips the same lines — report §2.3.4).
pub fn text_records_keyed(
  text : String,
  timestamp : Int64,
  mode : KeyMode,
) -> ShapedText {
  let records : Array[@protocol.Record] = []
  let mut skipped = 0
  for line in text.split("\n") {
    let line = line.to_owned()
    let line = if line.has_suffix("\r") {
      line[0:line.length() - 1].to_owned()
    } else {
      line
    }
    if line.length() > 0 {
      let shaped : (Bytes, StringView)? = match mode {
        NoKey => Some((b"", line[0:line.length()]))
        ConstKey(key) => Some((key, line[0:line.length()]))
        SplitAt(sep) =>
          match line.find(sep) {
            Some(at) =>
              Some(
                (
                  @utf8.encode(line[0:at]),
                  line[at + sep.length():line.length()],
                ),
              )
            None => None
          }
      }
      match shaped {
        Some((key, value)) =>
          records.push(@protocol.Record::{
            timestamp,
            key,
            value: @utf8.encode(value),
            headers: [],
          })
        None => skipped = skipped + 1
      }
    }
  }
  ShapedText::{ records, skipped }
}

///|
/// Keyed file read for `produce`: the same reader and the same shaping
/// rule as `file_source` (`file_source` itself delegates to
/// `text_records_keyed` with `NoKey`), plus the key mode and the skip
/// count the command reports.
pub fn file_records_keyed(
  path : String,
  timestamp : Int64,
  mode : KeyMode,
) -> Result[ShapedText, String] {
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => return Err("read \{path}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  Ok(text_records_keyed(text, timestamp, mode))
}

///|
pub fn value_text(r : @protocol.Record) -> String {
  @utf8.decode_lossy(r.value[0:r.value.length()])
}

///|
/// File source: newline-delimited text from a local path.
pub fn file_source(path : String, timestamp : Int64) -> Source {
  Source::{
    name: "file:\{path}",
    pull: fn() {
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(e) => return Err("read \{path}: \{e}")
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      Ok(records_from_text(text, timestamp))
    },
  }
}

///|
/// Stdin source: newline-delimited text from standard input to EOF.
pub fn stdin_source(timestamp : Int64) -> Source {
  Source::{
    name: "stdin",
    pull: fn() {
      let bytes = match @fs.read_stdin() {
        Ok(bytes) => bytes
        Err(e) => return Err("read stdin: \{e}")
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      Ok(records_from_text(text, timestamp))
    },
  }
}

///|
/// HTTP GET source: fetch a URL, split the response body into lines.
pub fn http_source(url : String, timestamp : Int64) -> Source {
  Source::{
    name: "http-get:\{url}",
    pull: fn() {
      let body = match http_get(url) {
        Ok(body) => body
        Err(e) => return Err("GET \{url}: \{e}")
      }
      let text = @utf8.decode_lossy(body[0:body.length()])
      Ok(records_from_text(text, timestamp))
    },
  }
}

///|
/// Stdout sink: one line per record value.
pub fn stdout_sink() -> Sink {
  Sink::{
    name: "stdout",
    flush: fn(records) {
      for r in records {
        println(value_text(r))
      }
      Ok(())
    },
  }
}

///|
/// HTTP POST sink: newline-joined values in the request body.
pub fn http_sink(url : String) -> Sink {
  Sink::{
    name: "http-post:\{url}",
    flush: fn(records) {
      let body = Buffer::Buffer()
      for r in records {
        body.write_bytes(@utf8.encode(value_text(r))[0:0])
        let line = value_text(r)
        body.write_bytes(@utf8.encode(line[0:line.length()]))
        body.write_byte(b'\n')
      }
      match http_post(url, body.to_bytes()) {
        Ok(_) => Ok(())
        Err(e) => Err("POST \{url}: \{e}")
      }
    },
  }
}

// ---------------------------------------------------------------------------
// Minimal HTTP/1.1 client

///|
/// Parses "http://host[:port][/path]" into (host, port, path).
pub fn parse_http_url(url : String) -> Result[(String, Int, String), String] {
  if !url.has_prefix("http://") {
    return Err("only http:// URLs are supported")
  }
  let rest = url[7:url.length()].to_owned()
  let (authority, path) = match rest.find("/") {
    Some(idx) => (rest[0:idx].to_owned(), rest[idx:rest.length()].to_owned())
    None => (rest, "/")
  }
  if authority.length() == 0 {
    return Err("missing host in URL")
  }
  match authority.rev_split_once(":") {
    Some((host, port_text)) =>
      match (try? @string.parse_int(port_text[0:port_text.length()])) {
        Ok(port) => Ok((host.to_owned(), port, path))
        Err(_) => Err("bad port in URL: \{port_text}")
      }
    None => Ok((authority, 80, path))
  }
}

///|
/// Builds a plain HTTP/1.1 request (Connection: close keeps response
/// reading trivial: body runs to EOF).
pub fn build_http_request(
  verb : String,
  host : String,
  port : Int,
  path : String,
  body : Bytes,
) -> Bytes {
  let sb = StringBuilder::new()
  sb.write_string("\{verb} \{path} HTTP/1.1\r\n")
  if port == 80 {
    sb.write_string("Host: \{host}\r\n")
  } else {
    sb.write_string("Host: \{host}:\{port}\r\n")
  }
  sb.write_string("Connection: close\r\n")
  if verb == "POST" {
    sb.write_string("Content-Type: text/plain\r\n")
    sb.write_string("Content-Length: \{body.length()}\r\n")
  }
  sb.write_string("\r\n")
  let head_text = sb.to_string()
  let head = @utf8.encode(head_text[0:head_text.length()])
  let out = Buffer::Buffer()
  out.write_bytes(head[0:head.length()])
  if verb == "POST" {
    out.write_bytes(body[0:body.length()])
  }
  out.to_bytes()
}

///|
/// Splits a complete HTTP response into (status, body). Response
/// headers are discarded; the status line and the CRLFCRLF boundary
/// are validated.
pub fn parse_http_response(bytes : Bytes) -> Result[(Int, Bytes), String] {
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let boundary = match text.find("\r\n\r\n") {
    Some(idx) => idx
    None => return Err("response has no header terminator")
  }
  let head = text[0:boundary]
  let status_line = match head.split("\n").head() {
    Some(line) => line.to_owned()
    None => return Err("empty response")
  }
  // "HTTP/1.1 200 OK"
  let parts : Array[String] = []
  for part in status_line.split(" ") {
    parts.push(part.to_owned())
  }
  if parts.length() < 2 || !parts[0].has_prefix("HTTP/") {
    return Err("malformed status line: \{status_line}")
  }
  let status = match (try? @string.parse_int(parts[1][0:parts[1].length()])) {
    Ok(status) => status
    Err(_) => return Err("bad status code in: \{status_line}")
  }
  let body = bytes[boundary + 4:bytes.length()].to_owned()
  Ok((status, body))
}

///|
/// One blocking HTTP exchange over a fresh TCP connection.
fn http_exchange(
  verb : String,
  url : String,
  body : Bytes,
) -> Result[(Int, Bytes), String] {
  let (host, port, path) = match parse_http_url(url) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{host}:\{port}: \{e}")
  }
  let request = build_http_request(verb, host, port, path, body)
  match stream.send_all(request) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("send: \{e}")
    }
  }
  // read to EOF (Connection: close)
  let out = Buffer::Buffer()
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  while true {
    match stream.recv(chunk, 65536) {
      Ok(0) => break
      Ok(n) => {
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
  let (status, response_body) = match parse_http_response(out.to_bytes()) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  if status < 200 || status >= 300 {
    return Err("HTTP status \{status}")
  }
  Ok((status, response_body))
}

///|
/// HTTP GET returning the response body (2xx enforced).
pub fn http_get(url : String) -> Result[Bytes, String] {
  match http_exchange("GET", url, b"") {
    Ok((_, body)) => Ok(body)
    Err(e) => Err(e)
  }
}

///|
/// HTTP POST returning the response body (2xx enforced).
pub fn http_post(url : String, body : Bytes) -> Result[Bytes, String] {
  match http_exchange("POST", url, body) {
    Ok((_, response)) => Ok(response)
    Err(e) => Err(e)
  }
}
