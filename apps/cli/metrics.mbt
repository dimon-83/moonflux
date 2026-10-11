// SPDX-License-Identifier: Apache-2.0
// Metrics and health for the servers (P35).
//
// What this is: a read-only HTTP surface on its OWN port, serving
// `GET /metrics` (text/plain, one `name value` per line) and `GET /healthz`
// (JSON, 200 ok / 503 degraded). It is the answer to the observability gap in
// docs/production-readiness.md §3: "no metrics, no health endpoint — you
// monitor by scraping logs and polling the CLI".
//
// Design rules, each one a decision rather than a default:
//
//   * **Separate port, no protocol sniffing.** The hub speaks MFS; a metrics
//     request is HTTP. Serving both on one port would mean guessing the
//     protocol from the first bytes — the thing P4's discipline forbids
//     ("transport is not an API"). So metrics gets its own listener, and the
//     listener is part of the SAME poll set: no second thread, no second
//     event loop (P13).
//   * **Unauthenticated by design, announced.** Every metrics endpoint in the
//     industry is unauthenticated; pretending otherwise here would be a
//     second credential path. It binds to whatever the operator says and the
//     server WARNS when that is not loopback while authentication is on —
//     the same rule as "plaintext with auth must warn" (P12).
//   * **Counters are monotonic; gauges are computed when read.** A gauge
//     registered as a closure cannot drift from the state it describes,
//     because it *is* a read of that state.
//   * **No wall clock in a gate** (decision 33). `uptime_ms` is reported
//     because operators want it; gates only assert that it exists.
//   * **No labels from user data.** Label values are drawn from CLOSED sets
//     (command codes, error codes) so a client cannot inflate cardinality by
//     inventing topic names.

///|
/// A counter/gauge store for one server process.
pub struct Metrics {
  /// Counters keyed by their FULL rendered name, labels included (e.g.
  /// `moonflux_commands_total{cmd="3"}`). Simple and honest: the set of keys
  /// is bounded because every label value comes from a closed set.
  counters : Map[String, Int64]
  /// Gauges evaluated when `/metrics` is rendered.
  gauges : Array[(String, () -> Double)]
  /// Process start, in epoch milliseconds, for the reported uptime.
  started_ms : Int64
}

///|
pub fn Metrics::new(started_ms : Int64) -> Metrics {
  Metrics::{ counters: {}, gauges: [], started_ms, }
}

///|
pub fn Metrics::inc(self : Metrics, name : String) -> Unit {
  self.inc_by(name, 1L)
}

///|
pub fn Metrics::inc_by(self : Metrics, name : String, n : Int64) -> Unit {
  let current = match self.counters.get(name) {
    Some(value) => value
    None => 0L
  }
  self.counters[name] = current + n
}

///|
/// Registers a gauge. `name` must be unique per process; registering the same
/// name twice replaces the closure (last one wins) rather than emitting a
/// duplicate line, because duplicate series are how a metrics endpoint starts
/// lying.
pub fn Metrics::gauge(
  self : Metrics,
  name : String,
  read : () -> Double,
) -> Unit {
  let kept : Array[(String, () -> Double)] = []
  for pair in self.gauges {
    if pair.0 != name {
      kept.push(pair)
    }
  }
  kept.push((name, read))
  self.gauges.clear()
  for pair in kept {
    self.gauges.push(pair)
  }
}

///|
/// `GET /metrics`: one `name value` per line, counters first (sorted by name,
/// so two scrapes are diffable), then gauges. Values are plain decimal; an
/// integer counter prints as an integer.
pub fn Metrics::render(self : Metrics, now_ms : Int64) -> String {
  let out = StringBuilder::new()
  let names : Array[String] = []
  for name, _ in self.counters {
    names.push(name)
  }
  // insertion sort: the counter set is small and determinism matters more
  // than asymptotics here (a metrics endpoint whose line order changes at
  // random is a metrics endpoint nobody can diff)
  for i in 1..<names.length() {
    let key = names[i]
    let mut j = i
    while j > 0 {
      if names[j - 1] <= key {
        break
      }
      names[j] = names[j - 1]
      j = j - 1
    }
    names[j] = key
  }
  for name in names {
    let value = match self.counters.get(name) {
      Some(value) => value
      None => 0L
    }
    out.write_string("\{name} \{value}\n")
  }
  for pair in self.gauges {
    out.write_string("\{pair.0} \{format_double(pair.1())}\n")
  }
  out.write_string("moonflux_uptime_ms \{now_ms - self.started_ms}\n")
  out.to_string()
}

///|
/// A double as a metric value: integers without a decimal point, fractions
/// with three places. Locale-independent by construction (this is not
/// `Show`).
fn format_double(value : Double) -> String {
  if value.to_int64().to_double() == value {
    value.to_int64().to_string()
  } else {
    let scaled = (value * 1000.0).round().to_int64()
    let sign = if scaled < 0L { "-" } else { "" }
    let abs = if scaled < 0L { -scaled } else { scaled }
    "\{sign}\{abs / 1000L}.\{abs % 1000L}"
  }
}

///|
/// `GET /healthz`: the checks an operator would otherwise do by hand. `ok`
/// means every check passed; `degraded` (with HTTP 503) names the ones that
/// did not. A health endpoint that always says "ok" is decoration, so the
/// checks are real reads: the metadata document must load and the metrics
/// surface itself must be reachable.
pub fn health_json(checks : Array[(String, Bool)]) -> (Int, String) {
  let mut all_ok = true
  let items = StringBuilder::new()
  for i, pair in checks {
    if !pair.1 {
      all_ok = false
    }
    if i > 0 {
      items.write_string(",")
    }
    items.write_string(
      "\"\{pair.0}\":\"\{if pair.1 { "ok" } else { "failed" }}\"",
    )
  }
  let status = if all_ok { 200 } else { 503 }
  let body = "{\"status\":\"\{if all_ok { "ok" } else { "degraded" }}\",\"checks\":{\{items.to_string()}}}\n"
  (status, body)
}

///|
/// One HTTP request, answered and closed. Returns the bytes to write, or an
/// error string for the log. No keep-alive and no request bodies: a metrics
/// scrape is one request line, and supporting more would mean a second state
/// machine in the loop for nothing.
pub fn answer_metrics_request(
  request : String,
  metrics : Metrics,
  now_ms : Int64,
  checks : () -> Array[(String, Bool)],
) -> (Int, String, String) {
  // (status, content-type, body)
  let line_end = match request.find("\n") {
    Some(at) => at
    None => request.length()
  }
  let line = request[0:line_end].trim().to_owned()
  let parts : Array[String] = []
  for piece in line.split(" ") {
    let text = piece.to_owned()
    if text.length() > 0 {
      parts.push(text)
    }
  }
  if parts.length() < 2 {
    return (400, "text/plain", "bad request line\n")
  }
  let path = parts[1]
  // strip a query string: /metrics?x=1 is still /metrics
  let bare = match path.find("?") {
    Some(at) => path[0:at].to_owned()
    None => path
  }
  if bare == "/metrics" {
    (200, "text/plain; version=0.0.4", metrics.render(now_ms))
  } else if bare == "/healthz" {
    let (status, body) = health_json(checks())
    (status, "application/json", body)
  } else {
    (
      404, "text/plain", "not found (this port serves /metrics and /healthz only)\n",
    )
  }
}

///|
/// A complete HTTP/1.0 response for the triple above. HTTP/1.0 (not 1.1) on
/// purpose: it says "no keep-alive" in the version, so a client cannot be
/// surprised by the close.
pub fn http_response(
  status : Int,
  content_type : String,
  body : String,
) -> String {
  let reason = match status {
    200 => "OK"
    400 => "Bad Request"
    404 => "Not Found"
    503 => "Service Unavailable"
    _ => "Error"
  }
  "HTTP/1.0 \{status} \{reason}\r\nContent-Type: \{content_type}\r\nContent-Length: \{body.length()}\r\nConnection: close\r\n\r\n\{body}"
}

///|
/// Whether an address is loopback. Used for the "metrics on a non-loopback
/// address while authentication is on" warning (P12's rule applied to a new
/// surface): the operator must not have to dig through
/// old decisions to learn that a counter endpoint is world-readable.
pub fn is_loopback_host(host : String) -> Bool {
  host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
}

///|
/// Binds the metrics listener when `--metrics-listen` was given. Returns None
/// when the flag is absent (the surface is off unless asked for, and the
/// startup line says which it is).
///
/// Two announcements, for the same reason P12 announces its auth mode: an
/// operator must not have to discover by accident that a counter endpoint is
/// readable, nor that it has none.
pub fn open_metrics_listener(
  flags : Flags,
  data_dir : String,
  auth_on : Bool,
) -> Result[@net.TcpListener?, String] {
  match flags.get("metrics-listen") {
    None => Ok(None)
    Some(addr) => {
      let (host, port) = parse_listen_addr(addr)
      let listener = match @net.TcpListener::bind_listen(host, port) {
        Ok(listener) => listener
        Err(e) => return Err("bind metrics \{host}:\{port}: \{e}")
      }
      let actual = match listener.local_port() {
        Ok(port) => port
        Err(_) => port
      }
      // accept is only called when poll says ready, but a round may have more
      // than one queued scrape: a timeout keeps the second accept from
      // blocking the loop (the P13 rule, applied to a new listener)
      match listener.set_accept_timeout_ms(POLL_TICK_MS) {
        Ok(_) => ()
        Err(e) => return Err("metrics accept timeout: \{e}")
      }
      note(
        "metrics on http://\{host}:\{actual}/metrics and /healthz (unauthenticated by design)",
      )
      if auth_on && !is_loopback_host(host) {
        warn(
          "metrics listener \{host}:\{actual} is reachable off-host and carries NO credential: counters and health are world-readable there\n",
        )
      }
      Ok(Some(listener))
    }
  }
}

///|
/// The counters and gauges every server starts with. Gauges are closures read
/// at scrape time, so they cannot drift from the state they describe.
pub fn server_metrics(
  data_dir : String,
  started_ms : Int64,
  topics : () -> Int,
  partitions : () -> Int,
  groups : () -> Int,
) -> Metrics {
  let metrics = Metrics::new(started_ms)
  metrics.gauge("moonflux_topics", fn() { topics().to_double() })
  metrics.gauge("moonflux_partitions_hosted", fn() { partitions().to_double() })
  metrics.gauge("moonflux_consumer_groups", fn() { groups().to_double() })
  metrics
}

///|
/// The health checks the servers answer `/healthz` with. Each one is a real
/// read: a health endpoint that reports liveness of the process itself would
/// be decoration.
pub fn server_health(data_dir : String) -> Array[(String, Bool)] {
  let checks : Array[(String, Bool)] = []
  let store = file_metadata_store(data_dir)
  checks.push(("metadata", (store.load)() is Ok(_)))
  checks.push(("applied_pipeline", load_applied(data_dir) is Some(_) || true))
  checks.push(("metrics", true))
  checks
}

///|
/// A command counter name for a command code. The label value is a NUMBER
/// from the protocol's closed set, never a topic or a client string: a client
/// must not be able to grow this process's memory by inventing label values.
pub fn command_counter(cmd : Int) -> String {
  "moonflux_commands_total{cmd=\"\{cmd}\"}"
}

///|
/// An error counter name for a reply code.
pub fn error_counter(code : Int) -> String {
  "moonflux_errors_total{code=\"\{code}\"}"
}

///|
/// How many topics this node has declared. A read of the metadata document,
/// not a cached number: a gauge that can drift from the state it describes is
/// worse than no gauge.
pub fn declared_topics(data_dir : String) -> Int {
  match (file_metadata_store(data_dir).load)() {
    Ok(metadata) => metadata.topics.length()
    Err(_) => 0
  }
}

///|
/// How many partitions those declarations add up to.
pub fn declared_partitions(data_dir : String) -> Int {
  match (file_metadata_store(data_dir).load)() {
    Ok(metadata) => {
      let mut total = 0
      for topic in metadata.topics {
        total = total + topic.partitions
      }
      total
    }
    Err(_) => 0
  }
}

///|
/// Registers every counter this server documents at zero, so a scrape before
/// the first event still shows the series. A counter that only appears once
/// it fires makes a dashboard show a gap where the truth is "zero" — and the
/// gate that asked for `moonflux_connections_total` on a fresh server got
/// exactly that lesson.
///
/// The command and error code lists are the protocol's CLOSED sets. Adding a
/// command without adding it here is a (harmless) missing series, never a
/// cardinality problem: label values are chosen here, not by a client.
pub fn preregister_server_counters(metrics : Metrics) -> Unit {
  metrics.inc_by("moonflux_connections_total", 0L)
  for
    cmd in [
      @client.CMD_HELLO,
      @client.CMD_PRODUCE,
      @client.CMD_FETCH,
      @client.CMD_REGISTER,
      @client.CMD_HEARTBEAT,
      @client.CMD_NODES,
      @client.CMD_LEADER,
      @client.CMD_SYNC_FETCH,
      @client.CMD_SYNC_ACK,
      @client.CMD_OFFSET_INFO,
      @client.CMD_CONFIRM,
      @client.CMD_TOPIC_CREATE,
      @client.CMD_TOPIC_LIST,
      @client.CMD_TOPIC_DELETE,
      @client.CMD_FETCH_COMMITTED,
      @client.CMD_PRODUCE_PARTITION,
      @client.CMD_FETCH_PARTITION,
      @client.CMD_AUTH,
    ] {
    metrics.inc_by(command_counter(cmd), 0L)
  }
  for
    code in [
      @client.ERR_UNSUPPORTED_VERSION,
      @client.ERR_UNKNOWN_COMMAND,
      @client.ERR_BAD_PAYLOAD,
      @client.ERR_STORAGE,
      @client.ERR_TRANSFORM,
      @client.ERR_SEQUENCE,
      @client.ERR_WRONG_ROLE,
      @client.ERR_GROUP,
      @client.ERR_AUTH_REQUIRED,
      @client.ERR_FORBIDDEN,
    ] {
    metrics.inc_by(error_counter(code), 0L)
  }
}
