// SPDX-License-Identifier: Apache-2.0
// apps/editor-kernel: the Web editor's kernel side, compiled to
// wasm-gc so it runs in the browser.
//
// The division of labor is the whole point (README decision 7,
// AGENTS §1 rule 7): the editor *renders* a spec, it never defines one.
// The page's drag-and-drop graph is an input; this module turns it into
// a PipelineSpec document, validates it with the same `core/spec`
// parser the CLI uses, compiles it with the same `core/pipeline`
// compiler, and speaks the same frame protocol through `core/client`'s
// codecs. Nothing about the spec or the protocol is re-implemented in
// JavaScript — the browser gets the kernel, not a reimagining of it.
//
// Transport: the page owns the WebSocket and this module owns the
// session. JS calls `feed` when a message arrives and sends whatever
// the request builders return; a browser socket cannot be read
// synchronously, and a state machine is the honest shape for that.

///|
/// ABI version for the page to check (the same discipline the operator
/// ABI uses: a mismatch is refused, not guessed). 2 adds the function-
/// set surface (P27): an old artifact staged next to the new page would
/// leave the panel silently missing, so the page asserts the version
/// instead of discovering that by absence.
pub fn mf_editor_abi_version() -> Int {
  2
}

// ---------------------------------------------------------------------
// Graph -> spec. The UI's shape is not the spec's shape: this is where
// the mapping lives, so a UI change cannot quietly change the format.

///|
/// Builds a v1alpha1 Pipeline document from the editor's graph.
///
/// Input (JSON):
///   { "name": "demo",
///     "source": { "type": "file", "path": "..." } | {"type":"stdin"} |
///               { "type": "http", "url": "..." },
///     "transforms": [ {"kind":"expr","expr":"upper(value)"} |
///                     {"kind":"wasm","module":"ops/x.wasm"} ],
///     "topic": "events",
///     "sink": { "type": "stdout" } | { "type": "http", "url": "..." } }
///
/// Output: the spec document, or a JSON error object.
pub fn mf_editor_build_spec(graph : String) -> String {
  let json = @json.parse(graph[0:graph.length()]) catch {
    e => return json_error("graph is not valid JSON: \{e}")
  }
  let obj = match json {
    Object(obj) => obj
    _ => return json_error("graph must be an object")
  }
  let name = match obj.get("name") {
    Some(String(name)) => name
    _ => "editor-pipeline"
  }
  let topic = match obj.get("topic") {
    Some(String(topic)) => topic
    _ => return json_error("the graph needs a topic")
  }
  let source = match obj.get("source") {
    Some(Object(source)) => source
    _ => return json_error("the graph needs a source")
  }
  let sink = match obj.get("sink") {
    Some(Object(sink)) => sink
    _ => return json_error("the graph needs a sink")
  }
  let source_doc : Map[String, Json] = {}
  let source_type = match source.get("type") {
    Some(String(t)) => t
    _ => return json_error("the source needs a type")
  }
  source_doc["type"] = Json::string(source_type)
  match source_type {
    "file" =>
      match source.get("path") {
        Some(String(path)) => source_doc["path"] = Json::string(path)
        _ => return json_error("a file source needs a path")
      }
    "http" =>
      match source.get("url") {
        Some(String(url)) => source_doc["url"] = Json::string(url)
        _ => return json_error("an http source needs a url")
      }
    "stdin" => ()
    _ => return json_error("unknown source type '\{source_type}'")
  }
  let sink_doc : Map[String, Json] = {}
  let sink_type = match sink.get("type") {
    Some(String(t)) => t
    _ => return json_error("the sink needs a type")
  }
  sink_doc["type"] = Json::string(sink_type)
  if sink_type == "http" {
    match sink.get("url") {
      Some(String(url)) => sink_doc["url"] = Json::string(url)
      _ => return json_error("an http sink needs a url")
    }
  } else if sink_type != "stdout" {
    return json_error("unknown sink type '\{sink_type}'")
  }
  let transforms : Array[Json] = []
  match obj.get("transforms") {
    Some(Array(items)) =>
      for item in items {
        let t = match item {
          Object(t) => t
          _ => return json_error("each transform must be an object")
        }
        let kind = match t.get("kind") {
          Some(String(kind)) => kind
          _ => return json_error("each transform needs a kind")
        }
        let doc_map : Map[String, Json] = {}
        match kind {
          "expr" =>
            match t.get("expr") {
              Some(String(expr)) => {
                doc_map["type"] = Json::string("expr")
                doc_map["expr"] = Json::string(expr)
                // an expr transform may reference a function set by name
                // (P6's `$.spec.transforms[i].functions`); the name is
                // resolved — and refused if missing — when the node
                // applies the spec, so the editor only carries it
                match t.get("functions") {
                  Some(String(set_name)) =>
                    if set_name.length() > 0 {
                      doc_map["functions"] = Json::string(set_name)
                    }
                  Some(_) =>
                    return json_error(
                      "functions must name a function set (a string)",
                    )
                  None => ()
                }
              }
              _ => return json_error("an expr transform needs an expr")
            }
          "wasm" => {
            // the reference lives on the expr transform only; a silent
            // ignore here would drop a setting the user can see
            match t.get("functions") {
              Some(_) =>
                return json_error(
                  "only an expr transform can reference a function set",
                )
              None => ()
            }
            match t.get("module") {
              Some(String(module)) => {
                doc_map["type"] = Json::string("wasm")
                doc_map["module"] = Json::string(module)
              }
              _ => return json_error("a wasm transform needs a module")
            }
          }
          _ => return json_error("unknown transform kind '\{kind}'")
        }
        transforms.push(Json::object(doc_map))
      }
    Some(_) => return json_error("transforms must be an array")
    None => ()
  }
  let metadata : Map[String, Json] = {}
  metadata["name"] = Json::string(name)
  let spec_doc : Map[String, Json] = {}
  spec_doc["source"] = Json::object(source_doc)
  spec_doc["transforms"] = Json::array(transforms)
  let topic_doc : Map[String, Json] = {}
  topic_doc["name"] = Json::string(topic)
  spec_doc["topic"] = Json::object(topic_doc)
  spec_doc["sink"] = Json::object(sink_doc)
  let root : Map[String, Json] = {}
  root["apiVersion"] = Json::string(@spec.SPEC_API_VERSION)
  root["kind"] = Json::string(@spec.SPEC_KIND)
  root["metadata"] = Json::object(metadata)
  root["spec"] = Json::object(spec_doc)
  Json::object(root).stringify(indent=2)
}

// ---------------------------------------------------------------------
// Validation and planning: the kernel's own answers, not the page's.

///|
/// Validates a spec document and, when it is valid, reports the
/// topology it compiles to. Output is JSON either way:
///   { "ok": true, "pipeline": "...", "processes": [ {name, role, capability, detail}, ...] }
///   { "ok": false, "errors": [ {path, code, message}, ... ] }
pub fn mf_editor_validate(spec_json : String) -> String {
  match @spec.parse_spec(spec_json) {
    Err(errors) => {
      let items : Array[Json] = []
      for error in errors {
        let item : Map[String, Json] = {}
        item["path"] = Json::string(error.path)
        item["code"] = Json::string(error.code)
        item["message"] = Json::string(error.message)
        items.push(Json::object(item))
      }
      let root : Map[String, Json] = {}
      root["ok"] = false.to_json()
      root["errors"] = Json::array(items)
      json_bytes(root)
    }
    Ok(spec) => {
      let topology = @pipeline.compile(spec)
      let processes : Array[Json] = []
      for process in topology.processes {
        let item : Map[String, Json] = {}
        item["name"] = Json::string(process.name)
        item["role"] = Json::string(process.role)
        item["capability"] = Json::string(process.capability)
        item["detail"] = Json::string(process.detail)
        processes.push(Json::object(item))
      }
      let root : Map[String, Json] = {}
      root["ok"] = true.to_json()
      root["pipeline"] = Json::string(topology.pipeline)
      root["runnable"] = @pipeline.runnable(topology).to_json()
      root["processes"] = Json::array(processes)
      json_bytes(root)
    }
  }
}

// ---------------------------------------------------------------------
// Session: the request builders and the reply decoder. Every byte here
// goes through core/client's codecs — the page never assembles a frame.

///|
/// Session state: the request-id counter and the last decoded outcome.
/// A browser socket delivers asynchronously, so the module keeps the
/// protocol's bookkeeping and JS keeps the socket.
priv struct Session {
  mut next_rid : Int
}

///|
let session : Session = Session::{ next_rid: 1, }

///|
/// Resets the session (a new connection starts over).
pub fn mf_editor_session_reset() -> Unit {
  session.next_rid = 1
}

///|
/// The HELLO frame a fresh session must send first.
pub fn mf_editor_hello() -> Bytes {
  // the session frame: magic + version + cmd + rid + length + payload
  frame(@client.CMD_HELLO, 0, @client.encode_hello(1, 0))
}

///|
/// An APPLY_PIPELINE request carrying the spec document.
pub fn mf_editor_apply(spec_json : String) -> Bytes {
  let bytes = @utf8.encode(spec_json[0:spec_json.length()])
  request(@client.CMD_APPLY_PIPELINE, bytes)
}

///|
/// A PRODUCE request: the editor acts as the pipeline's source, so
/// "run" in the UI means "feed these records into the topic".
/// `records_json` is an array of `{"key": "...", "value": "..."}`.
pub fn mf_editor_produce(topic : String, records_json : String) -> Bytes {
  let topic_text = topic
  let json = @json.parse(records_json[0:records_json.length()]) catch {
    e => return b""
  }
  let items = match json {
    Array(items) => items
    _ => return b""
  }
  let records : Array[@protocol.Record] = []
  for item in items {
    let obj = match item {
      Object(obj) => obj
      _ => continue
    }
    let key = match obj.get("key") {
      Some(String(key)) => key
      _ => ""
    }
    let value = match obj.get("value") {
      Some(String(value)) => value
      _ => ""
    }
    records.push(@protocol.Record::{
      timestamp: 0L,
      key: @utf8.encode(key[0:key.length()]),
      value: @utf8.encode(value[0:value.length()]),
      headers: [],
    })
  }
  let payload = @buffer.Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic_text[0:topic_text.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  let batch = @protocol.encode_frame(-1L, records)
  payload.write_bytes(batch[0:batch.length()])
  request(@client.CMD_PRODUCE, payload.to_bytes())
}

///|
/// A FETCH request (Uncommitted: everything the log holds).
pub fn mf_editor_fetch(topic : String, from : Int64, max : Int) -> Bytes {
  let topic_text = topic
  let payload = @buffer.Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic_text[0:topic_text.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_int64_be(from)
  payload.write_uint_be(max.reinterpret_as_uint())
  request(@client.CMD_FETCH, payload.to_bytes())
}

// ---------------------------------------------------------------------
// Function sets (P27): the editor manages the rule assets a spec's
// expr transforms reference. The split is the same as everywhere else
// on this page — the kernel builds the asset document and the protocol
// bytes; the node's publish-time gate (mbel's own validation plus the
// purity scan) stays the only authority for everything beyond shape.

///|
/// Builds the asset document a function-set form edits into the JSON
/// the CREATE verb consumes.
///
/// Input (the form's shape):
///   { "name": "textkit",
///     "functions": [ { "name": "shout", "params": ["x"],
///                      "body": "upper(x) + \"!\"", "description": "…" } ] }
///
/// The pre-check is shape only: the set name reuses the project's one
/// name whitelist (`core/spec`, the same rule a topic name answers to),
/// and the required fields must be present and non-empty. mbel's rules
/// for names, parameters and bodies — and the purity scan — are the
/// node's create-time gate, deliberately not re-implemented here: a
/// second authority would drift from the first.
///
/// Output: `{ "ok": true, "asset": "<document>" }`, or
/// `{ "ok": false, "error": "…" }`.
pub fn mf_editor_build_function_set(form : String) -> String {
  let json = @json.parse(form[0:form.length()]) catch {
    e => return json_error("form is not valid JSON: \{e}")
  }
  let obj = match json {
    Object(obj) => obj
    _ => return json_error("the form must be an object")
  }
  let name = match obj.get("name") {
    Some(String(name)) => name
    _ => return json_error("the form needs a set name")
  }
  if !@spec.valid_topic_name(name) {
    return json_error("invalid set name '\{name}' (1..128 of [a-z0-9._-])")
  }
  let items = match obj.get("functions") {
    Some(Array(items)) => items
    _ => return json_error("the form needs a functions array")
  }
  if items.length() == 0 {
    return json_error("a function set needs at least one function")
  }
  let functions : Array[Json] = []
  for item in items {
    let f = match item {
      Object(f) => f
      _ => return json_error("each function must be an object")
    }
    let fn_name = match f.get("name") {
      Some(String(n)) => n
      _ => return json_error("each function needs a name")
    }
    if fn_name.length() == 0 {
      return json_error("a function name cannot be empty")
    }
    let params : Array[Json] = []
    match f.get("params") {
      Some(Array(raw)) =>
        for p in raw {
          match p {
            String(p) => params.push(Json::string(p))
            _ => return json_error("params must be strings")
          }
        }
      Some(_) => return json_error("params must be an array of strings")
      None => return json_error("each function needs params")
    }
    let body = match f.get("body") {
      Some(String(body)) => body
      _ => return json_error("function '\{fn_name}' needs a body")
    }
    if body.length() == 0 {
      return json_error("function '\{fn_name}' needs a body")
    }
    let doc : Map[String, Json] = {}
    doc["name"] = Json::string(fn_name)
    doc["params"] = Json::array(params)
    doc["body"] = Json::string(body)
    match f.get("description") {
      Some(String(text)) =>
        // an empty description is "none", not "" — the asset should not
        // carry a field that says nothing
        if text.length() > 0 {
          doc["description"] = Json::string(text)
        }
      Some(_) => return json_error("description must be a string")
      None => ()
    }
    functions.push(Json::object(doc))
  }
  let set_map : Map[String, Json] = {}
  set_map["name"] = Json::string(name)
  set_map["functions"] = Json::array(functions)
  let root : Map[String, Json] = {}
  root["ok"] = true.to_json()
  root["asset"] = Json::string(Json::object(set_map).stringify(indent=2))
  json_bytes(root)
}

///|
/// A FUNCTION_SET_CREATE request carrying the asset document.
pub fn mf_editor_function_set_create(asset_json : String) -> Bytes {
  request(
    @client.CMD_FUNCTION_SET_CREATE,
    @utf8.encode(asset_json[0:asset_json.length()]),
  )
}

///|
/// A FUNCTION_SET_LIST request (the reply is every set's full document:
/// name, revision, functions — the panel and the form load from it).
pub fn mf_editor_function_set_list() -> Bytes {
  request(@client.CMD_FUNCTION_SET_LIST, b"")
}

///|
/// A FUNCTION_SET_DELETE request naming the set.
pub fn mf_editor_function_set_delete(name : String) -> Bytes {
  request(@client.CMD_FUNCTION_SET_DELETE, @utf8.encode(name[0:name.length()]))
}

///|
/// Builds one request frame and returns its bytes for JS to send.
fn request(cmd : Int, payload : Bytes) -> Bytes {
  let rid = session.next_rid
  session.next_rid = rid + 1
  frame(cmd, rid, payload)
}

///|
/// One session-protocol frame (magic + version + cmd + request id +
/// payload length + payload). Kept here so the page never assembles
/// protocol bytes: it sends what these functions return.
fn frame(cmd : Int, rid : Int, payload : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MFS")
  out.write_byte(b'\x02')
  out.write_byte(cmd.to_byte())
  out.write_uint_be(rid.reinterpret_as_uint())
  out.write_uint_be(payload.length().reinterpret_as_uint())
  out.write_bytes(payload[0:payload.length()])
  out.to_bytes()
}

///|
/// Decodes one server reply into JSON for the page:
///   { "cmd": 5, "rid": 1, "kind": "ok"|"welcome"|"records"|"error",
///     ... }
/// Frames are decoded by core/client's codecs, so the page never
/// parses protocol bytes.
pub fn mf_editor_feed(reply : Bytes) -> String {
  if reply.length() < 13 {
    return json_error("short reply frame")
  }
  let head = reply[0:13]
  if head[0] != b'M' || head[1] != b'F' || head[2] != b'S' {
    return json_error("not an MFS frame")
  }
  let cmd = head[4].to_int()
  let rid = ((head[5].to_uint() << 24) |
  (head[6].to_uint() << 16) |
  (head[7].to_uint() << 8) |
  head[8].to_uint()).to_int()
  let payload = reply[13:reply.length()].to_owned()
  let root : Map[String, Json] = {}
  root["cmd"] = Json::number(cmd.to_double())
  root["rid"] = Json::number(rid.to_double())
  match cmd {
    @client.CMD_WELCOME => {
      root["kind"] = Json::string("welcome")
      let (major, minor) = match @client.decode_hello(payload) {
        Ok(pair) => pair
        Err(_) => (0, 0)
      }
      root["major"] = Json::number(major.to_double())
      root["minor"] = Json::number(minor.to_double())
    }
    @client.CMD_ERR => {
      let (code, message) = @client.decode_error(payload)
      root["kind"] = Json::string("error")
      root["code"] = Json::number(code.to_double())
      root["message"] = Json::string(message)
    }
    @client.CMD_OK =>
      // an OK carries either records (fetch), an applied-pipeline
      // summary, or a function-set reply (list/create); decide by what
      // the payload decodes to. The shapes are mutually exclusive by
      // construction: the binary ones start with a u32/uleb count, the
      // JSON ones with `[` or `{` — a JSON byte as a count is far past
      // every bound tried here.
      match decode_records(payload) {
        Some(records) => {
          root["kind"] = Json::string("records")
          root["records"] = Json::array(records)
        }
        None =>
          // JSON replies first: the applied-pipeline probe below reads
          // ulebs, and a JSON object's leading `{` (123) passes its
          // length bound — a create reply would impersonate an apply
          // reply (caught by driving the real page). A binary payload
          // simply fails the JSON parse and falls through.
          match decode_function_set_list_reply(payload) {
            Some(sets) => {
              root["kind"] = Json::string("function-sets")
              root["sets"] = Json::array(sets)
            }
            None =>
              match decode_function_set_created_reply(payload) {
                Some(fields) => {
                  root["kind"] = Json::string("function-set")
                  for key, value in fields {
                    root[key] = value
                  }
                }
                None =>
                  match decode_applied(payload) {
                    Some((name, processes)) => {
                      root["kind"] = Json::string("ok")
                      root["pipeline"] = Json::string(name)
                      root["processes"] = Json::number(processes.to_double())
                    }
                    None => root["kind"] = Json::string("ok")
                  }
              }
          }
      }
    _ => root["kind"] = Json::string("unknown")
  }
  json_bytes(root)
}

///|
/// Tries to decode a fetch reply (u32 batch count + frames) into
/// `{offset, key, value}` records.
fn decode_records(payload : Bytes) -> Array[Json]? {
  let reader = @codec.Reader::new(payload)
  let batch_count = match reader.read_u32_be() {
    Ok(count) => count.reinterpret_as_int()
    Err(_) => return None
  }
  if batch_count == 0 || batch_count > 1024 {
    return None
  }
  let out : Array[Json] = []
  for _ in 0..<batch_count {
    let frame_len = match reader.read_u32_be() {
      Ok(len) => len.reinterpret_as_int()
      Err(_) => return None
    }
    let frame = match reader.read_bytes(frame_len) {
      Ok(frame) => frame
      Err(_) => return None
    }
    match @protocol.decode_frame_strict(frame) {
      Ok(batch) => {
        let mut offset = batch.base_offset
        for record in batch.records {
          let item : Map[String, Json] = {}
          item["offset"] = Json::number(offset.to_double())
          item["key"] = Json::string(
            @utf8.decode_lossy(record.key[0:record.key.length()]),
          )
          item["value"] = Json::string(
            @utf8.decode_lossy(record.value[0:record.value.length()]),
          )
          out.push(Json::object(item))
          offset += 1L
        }
      }
      Err(_) => return None
    }
  }
  Some(out)
}

///|
/// Tries to decode an apply reply (uleb128 name length + name +
/// uleb128 process count).
fn decode_applied(payload : Bytes) -> (String, Int)? {
  let reader = @codec.Reader::new(payload)
  let len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(_) => return None
  }
  if len == 0 || len > 128 {
    return None
  }
  let name = match reader.read_bytes(len) {
    Ok(name) => @utf8.decode_lossy(name[0:name.length()])
    Err(_) => return None
  }
  let processes = match reader.read_uleb128_len() {
    Ok(count) => count
    Err(_) => return None
  }
  Some((name, processes))
}

///|
/// Tries to decode a function-set LIST reply: the payload is a JSON
/// array of the sets' full documents (`encode_function_set_doc`'s
/// shape — name, revision, functions), so the panel and the form load
/// straight from it. Binary payloads fail the parse and return None.
fn decode_function_set_list_reply(payload : Bytes) -> Array[Json]? {
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch { _ => return None }
  match json {
    Array(items) => Some(items)
    _ => None
  }
}

///|
/// Tries to decode a function-set CREATE reply: `{name, revision,
/// created}` (created = deployed-or-updated). Keyed on the `created`
/// field so no other JSON object on this channel can impersonate it.
fn decode_function_set_created_reply(payload : Bytes) -> Map[String, Json]? {
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch { _ => return None }
  match json {
    Object(obj) =>
      if obj.get("name") is Some(String(_)) && obj.get("created") is Some(_) {
        Some(obj)
      } else {
        None
      }
    _ => None
  }
}

///|
fn json_error(message : String) -> String {
  let root : Map[String, Json] = {}
  root["ok"] = false.to_json()
  root["error"] = Json::string(message)
  json_bytes(root)
}

///|
fn json_bytes(map : Map[String, Json]) -> String {
  Json::object(map).stringify()
}

///|
/// The module's entry point. The page drives everything through the
/// exports; main only proves the ABI answers.
fn main {
  let _ = mf_editor_abi_version()
}
