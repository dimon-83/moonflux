// SPDX-License-Identifier: Apache-2.0
// apps/connectors: Source/Sink framework (P1) — the external read/write
// edge of the data path. P1 ships: file, stdin, and HTTP GET sources;
// stdout and HTTP POST sinks. HTTP is a minimal plain-HTTP/1.1 client
// on top of net-native (the P1 scope cut: no TLS, no redirects, no
// chunked bodies beyond what the fixture needs). P19 adds a
// subscription source (MQTT) and gives the framework what a streaming
// source needs: a pull that can say "nothing right now" without lying
// "exhausted", or being re-read.
//
// Sources are pulls; the runner decides cadence (P1 ran a single pass
// per invocation; P19's runner loops until the source is exhausted,
// sleeping between quiet pulls).

///|
/// What one pull yielded (P19). A subscription source has no end and a
/// one-shot source has no "not yet" — without this distinction the
/// runner would either exit on the first quiet poll or replay a file
/// forever (`file_source` re-reads its path on every call, so a loop
/// that treats every pull as fresh data would append the whole file
/// again and again).
pub(all) enum SourcePull {
  /// records are available; ask again for more
  Records(Array[@protocol.Record])
  /// a streaming source, quiet right now: ask again later
  Quiet
  /// a one-shot source that has delivered everything it will ever have
  Exhausted
} derive(Debug)

///|
/// A data source: one pull yields the records currently available, or
/// says there are none (yet), or that there will be no more.
pub(all) struct Source {
  name : String
  pull : () -> Result[SourcePull, String]
}

///|
/// The state a one-shot source keeps so its second pull can say
/// `Exhausted` instead of replaying (a struct because a closure cannot
/// own a mutable field).
priv struct OnceState {
  mut delivered : Bool
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
  skipped : Int32
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
  ShapedText::{ records, skipped, }
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
/// File source: newline-delimited text from a local path. One-shot:
/// the first pull reads the whole file, the second says `Exhausted` —
/// the path is not tailed (a re-read would replay it).
pub fn file_source(path : String, timestamp : Int64) -> Source {
  let state = OnceState::{ delivered: false, }
  Source::{
    name: "file:\{path}",
    pull: fn() {
      if state.delivered {
        return Ok(Exhausted)
      }
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(e) => return Err("read \{path}: \{e}")
      }
      state.delivered = true
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      Ok(Records(records_from_text(text, timestamp)))
    },
  }
}

///|
/// Stdin source: newline-delimited text from standard input to EOF.
/// One-shot, same contract as the file source.
pub fn stdin_source(timestamp : Int64) -> Source {
  let state = OnceState::{ delivered: false, }
  Source::{
    name: "stdin",
    pull: fn() {
      if state.delivered {
        return Ok(Exhausted)
      }
      let bytes = match @fs.read_stdin() {
        Ok(bytes) => bytes
        Err(e) => return Err("read stdin: \{e}")
      }
      state.delivered = true
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      Ok(Records(records_from_text(text, timestamp)))
    },
  }
}

///|
/// Poll state for the HTTP source: whether a body has been delivered
/// yet, and when the last fetch happened (P30/T109).
priv struct PollState {
  mut delivered : Bool
  mut last_ms : Int64
}

///|
/// HTTP GET source: fetch a URL, split the response body into lines.
///
/// `interval_ms` 0 keeps the original one-shot behavior — HTTP GET is a
/// question, not a subscription: one body, then `Exhausted`. A positive
/// interval makes it a poller: `Quiet` until the interval has elapsed,
/// then the body again. Each delivered batch is stamped with its *fetch*
/// time (the arrival-time rule the MQTT source follows), and re-fetching
/// an unchanged body re-delivers the same records — deduplication is the
/// reader's problem, exactly as it is for any external poller.
pub fn http_source(
  url : String,
  timestamp : Int64,
  interval_ms : Int64,
  headers : Array[(String, String)],
  ca : String,
) -> Source {
  let state = PollState::{ delivered: false, last_ms: timestamp, }
  let polling = interval_ms > 0L
  Source::{
    name: if polling {
      "http-poll:\{url}"
    } else {
      "http-get:\{url}"
    },
    pull: fn() {
      let stamp = if polling {
        let now = @env.now().reinterpret_as_int64()
        if state.delivered && now - state.last_ms < interval_ms {
          // not yet due: a poller says "nothing right now", never
          // "nothing ever" — that is the difference from Exhausted
          return Ok(Quiet)
        }
        state.last_ms = now
        now
      } else {
        if state.delivered {
          return Ok(Exhausted)
        }
        timestamp
      }
      let body = match http_get(url, headers, ca) {
        Ok(body) => body
        Err(e) => return Err("GET \{url}: \{e}")
      }
      state.delivered = true
      let text = @utf8.decode_lossy(body[0:body.length()])
      Ok(Records(records_from_text(text, stamp)))
    },
  }
}

///|
/// Flushes the process's stdout. A redirected stdout is block-buffered
/// (the P4 lesson: a node's output is read *while* it runs, and a
/// streaming run never exits on its own) — without this, a subscription
/// pipeline's lines would sit in the buffer until someone killed it,
/// and the gate would be asserting on the absence of output rather than
/// its arrival. The symbol lives in the CLI's native shim; connectors
/// link into the CLI, which is where every run happens.
extern "C" fn flush_stdout() -> Unit = "mf_cli_flush"

///|
/// Stdout sink: one line per record value, flushed per batch so a
/// streaming run is readable while it runs.
pub fn stdout_sink() -> Sink {
  Sink::{
    name: "stdout",
    flush: fn(records) {
      for r in records {
        println(value_text(r))
      }
      if records.length() > 0 {
        flush_stdout()
      }
      Ok(())
    },
  }
}

///|
/// HTTP POST sink: newline-joined values in the request body.
pub fn http_sink(
  url : String,
  headers : Array[(String, String)],
  ca : String,
) -> Sink {
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
      match http_post(url, body.to_bytes(), headers, ca) {
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
pub fn parse_http_url(
  url : String,
) -> Result[(String, String, Int32, String), String] {
  let (scheme, default_port, head) = if url.has_prefix("https://") {
    ("https", 443, 8)
  } else if url.has_prefix("http://") {
    ("http", 80, 7)
  } else {
    return Err("URL must start with http:// or https://")
  }
  let rest = url[head:url.length()].to_owned()
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
        Ok(port) => Ok((scheme, host.to_owned(), port, path))
        Err(_) => Err("bad port in URL: \{port_text}")
      }
    None => Ok((scheme, authority, default_port, path))
  }
}

///|
/// Builds a plain HTTP/1.1 request (Connection: close keeps response
/// reading trivial: body runs to EOF).
pub fn build_http_request(
  verb : String,
  host : String,
  port : Int32,
  path : String,
  body : Bytes,
  headers : Array[(String, String)],
) -> Bytes {
  let sb = StringBuilder::new()
  sb.write_string("\{verb} \{path} HTTP/1.1\r\n")
  if port == 80 {
    sb.write_string("Host: \{host}\r\n")
  } else {
    sb.write_string("Host: \{host}:\{port}\r\n")
  }
  // NOTE: `for a, b in array` binds (index, element) in MoonBit, NOT a tuple
  // destructuring — the first version of this loop wrote "0: (name, value)" into
  // the request head. Destructure the element explicitly.
  for header in headers {
    let (name, value) = header
    sb.write_string("\{name}: \{value}\r\n")
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
pub fn parse_http_response(bytes : Bytes) -> Result[(Int32, Bytes), String] {
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

///|
/// Bounded waits for the https path. The http source is a poller: a peer that
/// accepts the connection and then goes quiet must not pin the pipeline.
const HTTP_HANDSHAKE_TIMEOUT_MS : Int32 = 10000

///|
const HTTP_IO_TIMEOUT_MS : Int32 = 30000

///|
/// Milliseconds from now. Read here (the host layer), never in the kernel.
fn http_deadline_after(ms : Int32) -> Int64 {
  @env.now().reinterpret_as_int64() + ms.to_int64()
}

///|
fn http_past_deadline(deadline : Int64) -> Bool {
  @env.now().reinterpret_as_int64() > deadline
}

///|
/// The `Content-Length` a response promises, if it says so. The two spellings
/// below cover what real servers send; anything else falls back to
/// "read until the peer closes", which the read loop also handles — so a server
/// we cannot measure is still read correctly, just less promptly.
fn response_content_length(bytes : Bytes) -> Int32? {
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  for marker in ["\r\nContent-Length: ", "\r\ncontent-length: "] {
    match text.find(marker) {
      None => ()
      Some(at) => {
        let rest = text[at + marker.length():text.length()]
        let mut digits = ""
        for part in rest.split("\r\n") {
          digits = part.to_owned()
          break
        }
        match (try? @string.parse_int(digits)) {
          Ok(n) => return Some(n)
          Err(_) => return None
        }
      }
    }
  }
  None
}

///|
/// Where the response header block ends (the body starts after it).
fn response_header_end(bytes : Bytes) -> Int32? {
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  match text.find("\r\n\r\n") {
    Some(at) => Some(at + 4)
    None => None
  }
}

///|
/// An https exchange.
///
/// Verification is not optional and there is NO implicit system trust store: an
/// http source is configured by a spec somebody reviews, so "which certificates
/// do we trust" has to be visible there. An empty CA is refused by name — both
/// "quietly trust nothing" and "quietly trust everything" are wrong answers to a
/// question nobody asked, and the second one is the dangerous one.
fn https_exchange(
  verb : String,
  host : String,
  port : Int32,
  path : String,
  body : Bytes,
  headers : Array[(String, String)],
  ca : String,
) -> Result[(Int32, Bytes), String] {
  if ca.length() == 0 {
    return Err(
      "https needs a trust anchor: set source.ca (there is no implicit system store)",
    )
  }
  let context = match @tls.client_context(ca, None, None) {
    Ok(context) => context
    Err(e) => return Err(e)
  }
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => {
      context.free()
      return Err("connect \{host}:\{port}: \{e}")
    }
  }
  match stream.set_nonblocking(true) {
    Ok(_) => ()
    Err(e) => {
      context.free()
      let _ = stream.close()
      return Err("nonblocking: \{e}")
    }
  }
  let session = match context.attach(stream.raw_fd()) {
    Ok(session) => session
    Err(e) => {
      context.free()
      let _ = stream.close()
      return Err(e)
    }
  }
  // the certificate must name the host we asked for (P12): verification that
  // ignores the name accepts any certificate the CA ever signed
  session.set_host(host)
  let fd = stream.raw_fd()
  let deadline = http_deadline_after(HTTP_HANDSHAKE_TIMEOUT_MS)
  let mut done = false
  let mut failure = ""
  while !done {
    match session.connect() {
      Ok(Done) => done = true
      Ok(Pending(want_write)) => {
        let _ = @net.poll_fds([fd], 50, want_write)
        if http_past_deadline(deadline) {
          failure = "TLS handshake timed out"
          break
        }
      }
      Err(e) => {
        failure = e
        break
      }
    }
  }
  if !done {
    session.close()
    let _ = stream.close()
    context.free()
    return Err("TLS to \{host}:\{port}: \{failure}")
  }
  let request = build_http_request(verb, host, port, path, body, headers)
  let outcome = https_exchange_ready(session, fd, request)
  session.close()
  let _ = stream.close()
  context.free()
  match outcome {
    Ok(response) => parse_http_response(response)
    Err(e) => Err(e)
  }
}

///|
/// Writes the request, then reads until the peer closes (the request asks for
/// `Connection: close`). One deadline covers both, so a peer that stalls is a
/// failure rather than a hang.
fn https_exchange_ready(
  session : @tls.TlsSession,
  fd : Int32,
  request : Bytes,
) -> Result[Bytes, String] {
  let deadline = http_deadline_after(HTTP_IO_TIMEOUT_MS)
  let mut sent = 0
  while sent < request.length() {
    match session.write_some(request[sent:request.length()].to_owned()) {
      Ok(Some(n)) => {
        if n == 0 {
          return Err("TLS write made no progress")
        }
        sent = sent + n
      }
      Ok(None) => {
        let _ = @net.poll_fds([fd], 50, true)
        if http_past_deadline(deadline) {
          return Err("TLS write timed out")
        }
      }
      Err(e) => return Err(e)
    }
  }
  let chunk : FixedArray[Byte] = FixedArray::make(65536, b'\x00')
  let out = Buffer::Buffer()
  while true {
    match session.read_some(chunk, 65536) {
      Ok(Some(0)) => break
      Ok(Some(n)) => {
        let part = Bytes::from_fixedarray(chunk, len=n)
        out.write_bytes(part[0:n])
        let so_far = out.to_bytes()
        // A complete response is the stop condition, not the peer closing: many
        // servers (python's http.server among them) end the connection without a
        // TLS close_notify, which OpenSSL 3 reports as an error rather than an
        // EOF. Reading by Content-Length sidesteps that entirely.
        match (response_content_length(so_far), response_header_end(so_far)) {
          (Some(want), Some(head)) =>
            if so_far.length() - head >= want {
              break
            }
          _ => ()
        }
        if so_far.length() > @protocol.MAX_BATCH_BYTES {
          return Err(
            "https response exceeds the payload budget (\{@protocol.MAX_BATCH_BYTES} bytes)",
          )
        }
        if http_past_deadline(deadline) {
          return Err("TLS read timed out")
        }
      }
      Ok(None) => {
        let _ = @net.poll_fds([fd], 50, false)
        if http_past_deadline(deadline) {
          return Err("TLS read timed out")
        }
      }
      Err(e) => {
        // OpenSSL 3 turns a missing close_notify into this error. Treating it as
        // end-of-stream is what every other client does in practice, and the
        // Content-Length check above is the real stop condition; refusing here
        // would reject a correct response from a server that simply closed.
        if e.contains("unexpected eof") {
          break
        }
        return Err(e)
      }
    }
  }
  Ok(out.to_bytes())
}

///|
fn http_exchange(
  verb : String,
  url : String,
  body : Bytes,
  headers : Array[(String, String)],
  ca : String,
) -> Result[(Int32, Bytes), String] {
  let (scheme, host, port, path) = match parse_http_url(url) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  if scheme == "https" {
    return https_exchange(verb, host, port, path, body, headers, ca)
  }
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{host}:\{port}: \{e}")
  }
  let request = build_http_request(verb, host, port, path, body, headers)
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
pub fn http_get(
  url : String,
  headers : Array[(String, String)],
  ca : String,
) -> Result[Bytes, String] {
  match http_exchange("GET", url, b"", headers, ca) {
    Ok((_, body)) => Ok(body)
    Err(e) => Err(e)
  }
}

///|
/// HTTP POST returning the response body (2xx enforced).
pub fn http_post(
  url : String,
  body : Bytes,
  headers : Array[(String, String)],
  ca : String,
) -> Result[Bytes, String] {
  match http_exchange("POST", url, body, headers, ca) {
    Ok((_, response)) => Ok(response)
    Err(e) => Err(e)
  }
}
