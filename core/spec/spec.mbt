// SPDX-License-Identifier: Apache-2.0
// core/spec: PipelineSpec v1alpha1 — the single source of truth for
// pipelines (golden rule 7). Pure parsing/validation, no IO; JSON is
// the on-the-wire/document form (a JSON document is also valid YAML,
// so YAML-authored specs using JSON syntax remain compatible).
//
// Validation collects ALL errors into a list so future editors can
// annotate every problem in one pass.

///|
/// The apiVersion this kernel understands.
pub const SPEC_API_VERSION = "moonflux.io/v1alpha1"

///|
/// The kind this kernel understands.
pub const SPEC_KIND = "Pipeline"

///|
/// One validation failure: JSON-path-style location, stable machine
/// code, human message.
pub(all) struct SpecError {
  path : String
  code : String
  message : String
} derive(Debug, Eq, Show)

///|
pub(all) enum SourceSpec {
  /// Read newline-delimited text from a local file path.
  FileSource(String)
  /// HTTP GET a URL; the response body splits into lines (P1).
  /// The `Int64` is the poll interval in milliseconds: 0 keeps the
  /// original one-shot behavior (one body, then `Exhausted`), a positive
  /// value makes it a polling source that re-fetches (P30/T109).
  HttpSource(String, Int64)
  /// Read newline-delimited text from standard input (P1).
  StdinSource
  /// Subscribe to an MQTT broker topic (P19); messages become records.
  MqttSource(String)
  /// Consume a Kafka topic partition (P20) — an interoperability
  /// endpoint, not a reference system.
  KafkaSource(String)
} derive(Debug, Eq, Show)

///|
/// v1alpha1 transform nodes. `expr` runs the mbel expression engine
/// (per record); `wasm` runs a compiled operator module through the
/// sandbox ABI (per batch, P2) with the operator's own JSON config.
/// Both execute on the consumption path.
pub(all) enum TransformSpec {
  /// expression + the function set it may call ("" = no set). The
  /// reference sits on the node that uses it, not on the spec as a
  /// whole: a pipeline's transforms are independently authored, and a
  /// global key would quietly apply to nodes that never call it.
  ExprTransform(String, String)
  /// module path + operator config (compact JSON text, "{}" = none)
  WasmTransform(String, String)
  /// ABI v2 scalar function name (P26): resolved through the node's
  /// scalar registry at apply time. The record's value is passed as
  /// one string argument; richer record-to-argument mapping awaits a
  /// real use case (the design's record-mapping boundary).
  ScalarTransform(String)
  /// A pattern for the kernel's own regex engine (P30/T111), used as a
  /// filter: a record passes when its value matches anywhere. `invert`
  /// keeps the records that do *not* match. The pattern is compiled at
  /// apply time, so an unsupported construct is a publish-time rejection
  /// instead of a per-record surprise.
  RegexTransform(String, Bool)
} derive(Debug, Eq, Show)

///|
pub(all) struct TopicSpec {
  name : String
} derive(Debug, Eq, Show)

///|
pub(all) enum SinkSpec {
  /// Write one line per record to standard output.
  StdoutSink
  /// HTTP POST the batch (newline-joined values) to a URL (P1).
  HttpSink(String)
  /// Publish each record's value to an MQTT broker topic (P19).
  MqttSink(String)
  /// Publish each batch to a Kafka topic partition (P20).
  KafkaSink(String)
} derive(Debug, Eq, Show)

///|
/// The spec-level shape check for an MQTT URL (P19): scheme plus a
/// non-empty authority and topic. The connector parses the parts; the
/// spec merely refuses to *store* a URL the connector would refuse to
/// open — a spec that validates is a spec whose failures happen at
/// apply time, not at 3 a.m.
fn mqtt_url_ok(url : String) -> Bool {
  if !url.has_prefix("mqtt://") || url.length() <= 7 {
    return false
  }
  let rest = url[7:url.length()].to_owned()
  match rest.split_once("/") {
    Some((authority, topic)) => authority.length() > 0 && topic.length() > 0
    None => false
  }
}

///|
/// The spec-level shape check for a Kafka URL (P20): scheme, authority,
/// topic, and parameters the connector would accept (`partition` a
/// non-negative integer, `from` earliest/latest/a non-negative offset,
/// nothing else).
fn kafka_url_ok(url : String) -> Bool {
  if !url.has_prefix("kafka://") || url.length() <= 8 {
    return false
  }
  let rest = url[8:url.length()].to_owned()
  let (head, query) = match rest.split_once("?") {
    Some((head, query)) => (head.to_owned(), query.to_owned())
    None => (rest, "")
  }
  let (authority, topic) = match head.split_once("/") {
    Some((authority, topic)) => (authority.to_owned(), topic.to_owned())
    None => return false
  }
  if authority.length() == 0 || topic.length() == 0 {
    return false
  }
  if query.length() > 0 {
    for pair in query.split("&") {
      let pair = pair.to_owned()
      match pair.split_once("=") {
        Some((key, value)) =>
          match key.to_owned() {
            "partition" =>
              match (try? @string.parse_int(value.to_owned())) {
                Ok(n) => if n < 0 { return false }
                Err(_) => return false
              }
            "from" =>
              match value.to_owned() {
                "earliest" | "latest" => ()
                other =>
                  match (try? @string.parse_int(other)) {
                    Ok(n) => if n < 0 { return false }
                    Err(_) => return false
                  }
              }
            // compression (P25): gzip is the one codec both this
            // platform and real brokers ship; unknown codecs are
            // refused at apply time, not discovered at run time
            "compression" =>
              match value.to_owned() {
                "gzip" | "none" => ()
                _ => return false
              }
            _ => return false
          }
        None => return false
      }
    }
  }
  true
}

///|
pub(all) struct PipelineSpec {
  metadata_name : String
  source : SourceSpec
  transforms : Array[TransformSpec]
  topic : TopicSpec
  sink : SinkSpec
  /// The topic a stateful operator node keeps its state in: a keyed log
  /// the host caches and compacts, never a second source of truth
  /// (docs/operator-abi-v3-state.md). None means the spec declares no
  /// state, and a stateful module in the chain is then refused at apply
  /// time rather than silently running without it (P30/T114).
  state : String?
} derive(Debug, Eq, Show)

///|
/// Shared rule for a required string field whose value must equal
/// `expected`: pushes exactly one error (bad-type / missing-field /
/// `code`) when violated.
fn expect_fixed_string(
  obj : Map[String, Json],
  path : String,
  key : String,
  expected : String,
  code : String,
  errors : Array[SpecError],
) -> Unit {
  match obj.get(key) {
    Some(String(s)) =>
      if s != expected {
        errors.push(SpecError::{
          path,
          code,
          message: "expected \"\{expected}\", got \"\{s}\"",
        })
      }
    Some(_) =>
      errors.push(SpecError::{
        path,
        code: "bad-type",
        message: "must be a string",
      })
    None =>
      errors.push(SpecError::{
        path,
        code: "missing-field",
        message: "required",
      })
  }
}

///|
/// Parses and validates a PipelineSpec document. Returns every
/// validation error found (empty list means success is impossible:
/// an `Err` always carries at least one error).
pub fn parse_spec(text : String) -> Result[PipelineSpec, Array[SpecError]] {
  let errors : Array[SpecError] = []
  let json = @json.parse(text[0:text.length()]) catch {
    e =>
      return Err([
        SpecError::{ path: "$", code: "invalid-json", message: "\{e}", },
      ])
  }
  if json is Object(root) {
    reject_unknown_keys(
      "$",
      root,
      ["apiVersion", "kind", "metadata", "spec"],
      errors,
    )
    // apiVersion + kind: required strings with fixed values
    expect_fixed_string(
      root,
      "$.apiVersion",
      "apiVersion",
      SPEC_API_VERSION,
      "bad-api-version",
      errors,
    )
    expect_fixed_string(root, "$.kind", "kind", SPEC_KIND, "bad-kind", errors)
    // metadata.name
    let name = match root.get("metadata") {
      Some(Object(meta)) => {
        reject_unknown_keys("$.metadata", meta, ["name"], errors)
        match meta.get("name") {
          Some(String(s)) =>
            if is_dns_label(s) {
              Some(s)
            } else {
              errors.push(SpecError::{
                path: "$.metadata.name",
                code: "bad-name",
                message: "must be a DNS-1123 label ([a-z0-9]([-a-z0-9]*[a-z0-9])?, max 63)",
              })
              None
            }
          _ => {
            errors.push(SpecError::{
              path: "$.metadata.name",
              code: "missing-field",
              message: "required string",
            })
            None
          }
        }
      }
      _ => {
        errors.push(SpecError::{
          path: "$.metadata",
          code: "missing-field",
          message: "required object",
        })
        None
      }
    }
    // spec.*
    let parsed_body = match root.get("spec") {
      Some(Object(body)) => {
        reject_unknown_keys(
          "$.spec",
          body,
          ["source", "transforms", "topic", "sink", "state"],
          errors,
        )
        parse_body(body, errors)
      }
      _ => {
        errors.push(SpecError::{
          path: "$.spec",
          code: "missing-field",
          message: "required object",
        })
        None
      }
    }
    match (name, parsed_body) {
      (Some(name), Some((source, transforms, topic, sink, state))) =>
        if errors.is_empty() {
          Ok(PipelineSpec::{
            metadata_name: name,
            source,
            transforms,
            topic,
            sink,
            state,
          })
        } else {
          Err(errors)
        }
      (_, _) => Err(errors)
    }
  } else {
    Err([
      SpecError::{
        path: "$",
        code: "bad-type",
        message: "document must be a JSON object",
      },
    ])
  }
}

///|
/// The HTTP source's optional poll interval: absent or 0 means "one
/// body, then done" — the P1 behavior — and a positive number means
/// "fetch again no sooner than that many milliseconds". Negative values
/// and non-numbers are rejected here, where the operator can still see
/// which key they typed (P30/T109).
fn parse_http_interval(
  src : Map[String, Json],
  errors : Array[SpecError],
) -> Int64? {
  match src.get("interval_ms") {
    None => Some(0L)
    Some(Number(n)) =>
      if n < 0.0 {
        errors.push(SpecError::{
          path: "$.spec.source.interval_ms",
          code: "bad-value",
          message: "interval_ms must not be negative (0 means one-shot)",
        })
        None
      } else {
        Some(n.to_int64())
      }
    Some(_) => {
      errors.push(SpecError::{
        path: "$.spec.source.interval_ms",
        code: "bad-value",
        message: "interval_ms must be a number of milliseconds",
      })
      None
    }
  }
}

///|
/// The optional `state` object: `{"topic": "..."}`. The state topic must
/// be a valid topic name and must differ from the pipeline's data topic —
/// a state log that is also the data log is a ring, and a ring in a log is
/// how a pipeline ends up reading its own output (P30/T114).
fn parse_state(
  body : Map[String, Json],
  topic : TopicSpec,
  errors : Array[SpecError],
) -> String? {
  match body.get("state") {
    None => None
    Some(Object(st)) => {
      reject_unknown_keys("$.spec.state", st, ["topic"], errors)
      match st.get("topic") {
        Some(String(name)) =>
          if !valid_topic_name(name) {
            errors.push(SpecError::{
              path: "$.spec.state.topic",
              code: "bad-value",
              message: "state topic must be a valid topic name",
            })
            None
          } else if name == topic.name {
            errors.push(SpecError::{
              path: "$.spec.state.topic",
              code: "bad-value",
              message: "state topic must differ from the data topic (\{name})",
            })
            None
          } else {
            Some(name)
          }
        Some(_) => {
          errors.push(SpecError::{
            path: "$.spec.state.topic",
            code: "bad-type",
            message: "state topic must be a string",
          })
          None
        }
        None => {
          errors.push(SpecError::{
            path: "$.spec.state.topic",
            code: "missing-field",
            message: "state requires a topic name",
          })
          None
        }
      }
    }
    Some(_) => {
      errors.push(SpecError::{
        path: "$.spec.state",
        code: "bad-type",
        message: "state must be an object ({\"topic\": \"...\"})",
      })
      None
    }
  }
}

///|
fn parse_body(
  body : Map[String, Json],
  errors : Array[SpecError],
) -> (SourceSpec, Array[TransformSpec], TopicSpec, SinkSpec, String?)? {
  // source
  let source : SourceSpec? = match body.get("source") {
    Some(Object(src)) => {
      reject_unknown_keys(
        "$.spec.source",
        src,
        ["type", "path", "url", "interval_ms"],
        errors,
      )
      match (src.get("type"), src.get("path"), src.get("url")) {
        (Some(String("file")), Some(String(path)), _) =>
          if path.length() == 0 {
            errors.push(SpecError::{
              path: "$.spec.source.path",
              code: "bad-value",
              message: "path must not be empty",
            })
            None
          } else {
            Some(FileSource(path))
          }
        (Some(String("http")), _, Some(String(url))) =>
          if url.has_prefix("http://") && url.length() > 7 {
            match parse_http_interval(src, errors) {
              Some(interval) => Some(HttpSource(url, interval))
              None => None
            }
          } else {
            errors.push(SpecError::{
              path: "$.spec.source.url",
              code: "bad-value",
              message: "url must start with http:// (P1 client speaks plain HTTP/1.1)",
            })
            None
          }
        (Some(String("http")), _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source.url",
            code: "missing-field",
            message: "http sources require a url",
          })
          None
        }
        (Some(String("stdin")), _, _) => Some(StdinSource)
        (Some(String("mqtt")), _, Some(String(url))) =>
          if mqtt_url_ok(url) {
            Some(MqttSource(url))
          } else {
            errors.push(SpecError::{
              path: "$.spec.source.url",
              code: "bad-value",
              message: "mqtt urls look like mqtt://[user:pass@]host[:port]/topic",
            })
            None
          }
        (Some(String("mqtt")), _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source.url",
            code: "missing-field",
            message: "mqtt sources require a url",
          })
          None
        }
        (Some(String("kafka")), _, Some(String(url))) =>
          if kafka_url_ok(url) {
            Some(KafkaSource(url))
          } else {
            errors.push(SpecError::{
              path: "$.spec.source.url",
              code: "bad-value",
              message: "kafka urls look like kafka://host:port/topic[?partition=N&from=earliest|latest|<offset>]",
            })
            None
          }
        (Some(String("kafka")), _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source.url",
            code: "missing-field",
            message: "kafka sources require a url",
          })
          None
        }
        (Some(String(other)), _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source.type",
            code: "bad-value",
            message: "unknown source type \"\{other}\" (supported: file, http, stdin, mqtt, kafka)",
          })
          None
        }
        (_, _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source",
            code: "bad-type",
            message: "type must be one of file/http/stdin with its required fields",
          })
          None
        }
      }
    }
    _ => {
      errors.push(SpecError::{
        path: "$.spec.source",
        code: "missing-field",
        message: "required object",
      })
      None
    }
  }
  // transforms (optional)
  let transforms : Array[TransformSpec] = match body.get("transforms") {
    None => []
    Some(Array(items)) => {
      let out : Array[TransformSpec] = []
      for i, item in items {
        let path = "$.spec.transforms[\{i}]"
        if item is Object(t) {
          reject_unknown_keys(
            path,
            t,
            [
              "type", "expr", "functions", "module", "config", "function", "pattern",
              "invert",
            ],
            errors,
          )
          match t.get("type") {
            Some(String("expr")) =>
              match t.get("expr") {
                Some(String(expr)) =>
                  if expr.length() == 0 {
                    errors.push(SpecError::{
                      path: "\{path}.expr",
                      code: "bad-value",
                      message: "expr must not be empty",
                    })
                  } else {
                    // the function-set reference is optional; when
                    // present it must name something, and the apply
                    // is what checks the name resolves (P6)
                    let functions = match t.get("functions") {
                      None => ""
                      Some(String(name)) =>
                        if name.length() == 0 {
                          errors.push(SpecError::{
                            path: "\{path}.functions",
                            code: "bad-value",
                            message: "functions must name a function set",
                          })
                          ""
                        } else {
                          name
                        }
                      Some(_) => {
                        errors.push(SpecError::{
                          path: "\{path}.functions",
                          code: "bad-type",
                          message: "functions must be a string (a function set name)",
                        })
                        ""
                      }
                    }
                    out.push(ExprTransform(expr, functions))
                  }
                _ =>
                  errors.push(SpecError::{
                    path: "\{path}.expr",
                    code: "missing-field",
                    message: "expr transforms require a string expr",
                  })
              }
            Some(String("wasm")) =>
              match t.get("module") {
                Some(String(mpath)) =>
                  if mpath.length() == 0 {
                    errors.push(SpecError::{
                      path: "\{path}.module",
                      code: "bad-value",
                      message: "module path must not be empty",
                    })
                  } else {
                    // operator config is guest-defined: the kernel only
                    // insists it be a JSON object, and passes the
                    // compact text through to mf_op_init.
                    match t.get("config") {
                      None => out.push(WasmTransform(mpath, "{}"))
                      Some(config) =>
                        if config is Object(_) {
                          out.push(WasmTransform(mpath, config.stringify()))
                        } else {
                          errors.push(SpecError::{
                            path: "\{path}.config",
                            code: "bad-type",
                            message: "config must be a JSON object",
                          })
                        }
                    }
                  }
                _ =>
                  errors.push(SpecError::{
                    path: "\{path}.module",
                    code: "missing-field",
                    message: "wasm transforms require a module path",
                  })
              }
            Some(String("scalar")) =>
              match t.get("function") {
                Some(String(fname)) =>
                  if fname.length() == 0 {
                    errors.push(SpecError::{
                      path: "\{path}.function",
                      code: "bad-value",
                      message: "scalar transforms need a function name",
                    })
                  } else {
                    out.push(ScalarTransform(fname))
                  }
                _ =>
                  errors.push(SpecError::{
                    path: "\{path}.function",
                    code: "missing-field",
                    message: "scalar transforms require a function name (resolved in the node's scalar registry)",
                  })
              }
            Some(String("regex")) =>
              match t.get("pattern") {
                Some(String(pattern)) =>
                  if pattern.length() == 0 {
                    errors.push(SpecError::{
                      path: "\{path}.pattern",
                      code: "bad-value",
                      message: "regex pattern must not be empty",
                    })
                  } else {
                    let invert = match t.get("invert") {
                      None => false
                      Some(True) => true
                      Some(False) => false
                      Some(_) => {
                        errors.push(SpecError::{
                          path: "\{path}.invert",
                          code: "bad-type",
                          message: "invert must be a boolean",
                        })
                        false
                      }
                    }
                    out.push(RegexTransform(pattern, invert))
                  }
                _ =>
                  errors.push(SpecError::{
                    path: "\{path}.pattern",
                    code: "missing-field",
                    message: "regex transforms require a string pattern",
                  })
              }
            Some(String(other)) =>
              errors.push(SpecError::{
                path: "\{path}.type",
                code: "bad-value",
                message: "unknown transform type \"\{other}\" (supported: expr, wasm, scalar, regex)",
              })
            _ =>
              errors.push(SpecError::{
                path: "\{path}.type",
                code: "bad-type",
                message: "must be a string",
              })
          }
        } else {
          errors.push(SpecError::{
            path,
            code: "bad-type",
            message: "transform must be an object",
          })
        }
      }
      out
    }
    Some(_) => {
      errors.push(SpecError::{
        path: "$.spec.transforms",
        code: "bad-type",
        message: "must be an array",
      })
      []
    }
  }
  // topic
  let topic : TopicSpec? = match body.get("topic") {
    Some(Object(t)) => {
      reject_unknown_keys("$.spec.topic", t, ["name"], errors)
      match t.get("name") {
        Some(String(name)) =>
          if valid_topic_name(name) {
            Some(TopicSpec::{ name, })
          } else {
            errors.push(SpecError::{
              path: "$.spec.topic.name",
              code: "bad-name",
              message: "must be 1..128 of [a-z0-9._-] (ASCII)",
            })
            None
          }
        _ => {
          errors.push(SpecError::{
            path: "$.spec.topic.name",
            code: "missing-field",
            message: "required string",
          })
          None
        }
      }
    }
    _ => {
      errors.push(SpecError::{
        path: "$.spec.topic",
        code: "missing-field",
        message: "required object",
      })
      None
    }
  }
  // sink
  let sink : SinkSpec? = match body.get("sink") {
    Some(Object(sk)) => {
      reject_unknown_keys("$.spec.sink", sk, ["type", "url"], errors)
      match (sk.get("type"), sk.get("url")) {
        (Some(String("stdout")), _) => Some(StdoutSink)
        (Some(String("http")), Some(String(url))) =>
          if url.has_prefix("http://") && url.length() > 7 {
            Some(HttpSink(url))
          } else {
            errors.push(SpecError::{
              path: "$.spec.sink.url",
              code: "bad-value",
              message: "url must start with http:// (P1 client speaks plain HTTP/1.1)",
            })
            None
          }
        (Some(String("http")), _) => {
          errors.push(SpecError::{
            path: "$.spec.sink.url",
            code: "missing-field",
            message: "http sinks require a url",
          })
          None
        }
        (Some(String("mqtt")), Some(String(url))) =>
          if mqtt_url_ok(url) {
            Some(MqttSink(url))
          } else {
            errors.push(SpecError::{
              path: "$.spec.sink.url",
              code: "bad-value",
              message: "mqtt urls look like mqtt://[user:pass@]host[:port]/topic",
            })
            None
          }
        (Some(String("mqtt")), _) => {
          errors.push(SpecError::{
            path: "$.spec.sink.url",
            code: "missing-field",
            message: "mqtt sinks require a url",
          })
          None
        }
        (Some(String("kafka")), Some(String(url))) =>
          if kafka_url_ok(url) {
            Some(KafkaSink(url))
          } else {
            errors.push(SpecError::{
              path: "$.spec.sink.url",
              code: "bad-value",
              message: "kafka urls look like kafka://host:port/topic[?partition=N&from=earliest|latest|<offset>]",
            })
            None
          }
        (Some(String("kafka")), _) => {
          errors.push(SpecError::{
            path: "$.spec.sink.url",
            code: "missing-field",
            message: "kafka sinks require a url",
          })
          None
        }
        (Some(String(other)), _) => {
          errors.push(SpecError::{
            path: "$.spec.sink.type",
            code: "bad-value",
            message: "unknown sink type \"\{other}\" (supported: stdout, http, mqtt, kafka)",
          })
          None
        }
        (_, _) => {
          errors.push(SpecError::{
            path: "$.spec.sink",
            code: "bad-type",
            message: "type must be one of stdout/http with its required fields",
          })
          None
        }
      }
    }
    _ => {
      errors.push(SpecError::{
        path: "$.spec.sink",
        code: "missing-field",
        message: "required object",
      })
      None
    }
  }
  match (source, topic, sink) {
    (Some(source), Some(topic), Some(sink)) =>
      Some((source, transforms, topic, sink, parse_state(body, topic, errors)))
    (_, _, _) => None
  }
}

///|
fn reject_unknown_keys(
  path : String,
  obj : Map[String, Json],
  allowed : Array[String],
  errors : Array[SpecError],
) -> Unit {
  for key, _ in obj {
    let mut known = false
    for a in allowed {
      if key == a {
        known = true
      }
    }
    if !known {
      errors.push(SpecError::{
        path: "\{path}.\{key}",
        code: "unknown-field",
        message: "not allowed here",
      })
    }
  }
}

///|
/// DNS-1123 label: lowercase alphanumerics and '-', must start and
/// end alphanumeric, max 63 chars.
fn is_dns_label(s : String) -> Bool {
  if s.length() == 0 || s.length() > 63 {
    return false
  }
  for i in 0..<s.length() {
    let c = s[i]
    let ok = (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      (c == 45 && i > 0 && i < s.length() - 1)
    if !ok {
      return false
    }
  }
  true
}

///|
/// Topic names share one whitelist across spec validation and the
/// CLI data-dir layout: 1..128 of [a-z0-9._-] (ASCII code points).
pub fn valid_topic_name(s : String) -> Bool {
  if s.length() == 0 || s.length() > 128 {
    return false
  }
  for i in 0..<s.length() {
    let c = s[i]
    let ok = (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 45 ||
      c == 46 ||
      c == 95
    if !ok {
      return false
    }
  }
  true
}
