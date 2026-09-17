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
  HttpSource(String)
  /// Read newline-delimited text from standard input (P1).
  StdinSource
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
} derive(Debug, Eq, Show)

///|
pub(all) struct PipelineSpec {
  metadata_name : String
  source : SourceSpec
  transforms : Array[TransformSpec]
  topic : TopicSpec
  sink : SinkSpec
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
        SpecError::{ path: "$", code: "invalid-json", message: "\{e}" },
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
          ["source", "transforms", "topic", "sink"],
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
      (Some(name), Some((source, transforms, topic, sink))) =>
        if errors.is_empty() {
          Ok(PipelineSpec::{
            metadata_name: name,
            source,
            transforms,
            topic,
            sink,
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
fn parse_body(
  body : Map[String, Json],
  errors : Array[SpecError],
) -> (SourceSpec, Array[TransformSpec], TopicSpec, SinkSpec)? {
  // source
  let source : SourceSpec? = match body.get("source") {
    Some(Object(src)) => {
      reject_unknown_keys("$.spec.source", src, ["type", "path", "url"], errors)
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
            Some(HttpSource(url))
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
        (Some(String(other)), _, _) => {
          errors.push(SpecError::{
            path: "$.spec.source.type",
            code: "bad-value",
            message: "unknown source type \"\{other}\" (supported: file, http, stdin)",
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
            ["type", "expr", "functions", "module", "config"],
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
            Some(String(other)) =>
              errors.push(SpecError::{
                path: "\{path}.type",
                code: "bad-value",
                message: "unknown transform type \"\{other}\" (supported: expr, wasm)",
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
        (Some(String(other)), _) => {
          errors.push(SpecError::{
            path: "$.spec.sink.type",
            code: "bad-value",
            message: "unknown sink type \"\{other}\" (supported: stdout, http)",
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
      Some((source, transforms, topic, sink))
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
