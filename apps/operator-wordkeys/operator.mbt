// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the key-stamping tokenizer.
//
// Config (through mf_op_init; unknown keys are refused):
//   {}                    split on single spaces
//   {"separator": ","}    split on that text (empty is refused)
//
// Each token becomes one record whose KEY is the token, so a downstream
// stateful operator can count per token. Empty tokens are dropped: a
// separator at the edge of a value is a delimiter, not a word.

///|
priv struct WordKeysState {
  mut separator : String
  /// keep the original value on each emitted record instead of the token:
  /// needed when the words are being used to INDEX something (an article
  /// title's words must not destroy the article)
  mut keep_value : Bool
  /// lowercase the emitted key: "Rust" and "rust" are one word for a lookup
  mut lowercase : Bool
  /// "" = split the whole value; otherwise split that JSON field's text
  /// (an article's words come from its TITLE, and splitting the whole JSON
  /// document yields JSON fragments — measured while porting
  /// hackernews-notify, which is exactly that shape)
  mut field : String
}

///|
let state : WordKeysState = WordKeysState::{
  separator: " ",
  keep_value: false,
  lowercase: false,
  field: "",
}

///|
pub fn mf_op_abi_version() -> Int32 {
  @sdk.abi_version()
}

///|
pub fn mf_op_alloc_input(len : Int32) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_init(config : Bytes) -> Int32 {
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "separator" | "keep_value" | "lowercase" | "field" => ()
      _ => return -1
    }
  }
  match cfg.get("field") {
    None => ()
    Some(_) =>
      match @sdk.config_string(cfg, "field") {
        Some(text) =>
          if text.length() == 0 {
            return -1
          } else {
            state.field = text
          }
        None => return -1
      }
  }
  match cfg.get("keep_value") {
    None => ()
    Some(True) => state.keep_value = true
    Some(False) => state.keep_value = false
    Some(_) => return -1
  }
  match cfg.get("lowercase") {
    None => ()
    Some(True) => state.lowercase = true
    Some(False) => state.lowercase = false
    Some(_) => return -1
  }
  if cfg.get("separator") is Some(_) {
    match @sdk.config_string(cfg, "separator") {
      Some(s) => {
        if s.length() == 0 {
          return -1
        }
        state.separator = s
      }
      None => return -1
    }
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let tokenizer = @sdk.GuestOperator::{
    name: "wordkeys",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let text = if state.field == "" {
          @utf8.decode_lossy(r.value[0:r.value.length()])
        } else {
          match @sdk.json_field(r.value, state.field) {
            Ok(Some(@sdk.ScalarText(t))) => t
            Ok(Some(_)) =>
              return Err("field \{state.field} is not text to split into words")
            Ok(None) =>
              return Err("field \{state.field} is missing from the record")
            Err(e) => return Err(e)
          }
        }
        for token in text.split(state.separator) {
          let word = token.to_owned()
          if word.length() > 0 {
            out.push(@protocol.Record::{
              timestamp: r.timestamp,
              key: @utf8.encode(
                if state.lowercase {
                  word.to_lower()
                } else {
                  word
                },
              ),
              value: if state.keep_value {
                r.value
              } else {
                @utf8.encode(word)
              },
              headers: r.headers,
            })
          }
        }
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(tokenizer, input)
  @sdk.buffered_output()
}

///|
pub fn mf_op_output_len() -> Int32 {
  @sdk.output_len()
}

///|
pub fn mf_op_last_status() -> Int32 {
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
