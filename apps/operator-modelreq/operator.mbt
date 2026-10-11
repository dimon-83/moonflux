// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the chat-request builder.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"default_model": "gpt-3.5-turbo", "models": ["gpt-4", "gpt-3.5-turbo"]}
//
// Input: one line of text per record.
// Output: `{"model": "...", "input": "..."}` where the model is the first
// word when the configured list knows it, and the default otherwise.
//
// The list is configuration rather than a hard-coded set: which models a
// deployment may call is an operational decision, and a guest that decides
// it silently cannot be audited. An empty list is refused at init — a
// request builder with no known models is a typo, not a policy.
//
// The whole line stays the input (as in the reference), including a leading
// model word when one is present: the endpoint is what decides how to read
// its own input, and this operator is not a parser for someone else's API.

///|
priv struct ModelReqState {
  mut default_model : String
  models : Array[String]
}

///|
let state : ModelReqState = ModelReqState::{
  default_model: "gpt-3.5-turbo",
  models: [],
}

///|
fn json_escape(text : String) -> String {
  let out = StringBuilder::new()
  for ch in text {
    match ch {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\t' => out.write_string("\\t")
      '\r' => out.write_string("\\r")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_init(config : Bytes) -> Int {
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "default_model" | "models" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "default_model") {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.default_model = text
    }
    None => return -1
  }
  match cfg.get("models") {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(name) =>
            if name.length() == 0 {
              return -1
            } else {
              state.models.push(name)
            }
          _ => return -1
        }
      }
    _ => return -1
  }
  if state.models.length() == 0 {
    return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let builder = @sdk.GuestOperator::{
    name: "modelreq",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let line = @utf8.decode_lossy(r.value[0:r.value.length()])
        let trimmed = line.trim().to_owned()
        let mut first = ""
        let mut seen_space = false
        for piece in trimmed.split(" ") {
          if !seen_space {
            first = piece.to_owned()
            seen_space = true
          }
        }
        let model = if state.models.contains(first) {
          first
        } else {
          state.default_model
        }
        let answer = "{\"model\":\"" +
          json_escape(model) +
          "\",\"input\":\"" +
          json_escape(trimmed) +
          "\"}"
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value: @utf8.encode(answer),
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(builder, input)
  @sdk.buffered_output()
}

///|
pub fn mf_op_output_len() -> Int {
  @sdk.output_len()
}

///|
pub fn mf_op_last_status() -> Int {
  @sdk.last_status()
}

///|
pub fn mf_op_last_error() -> Bytes {
  @sdk.last_error_bytes()
}

///|
fn main {
  let _ = mf_op_abi_version()
}
