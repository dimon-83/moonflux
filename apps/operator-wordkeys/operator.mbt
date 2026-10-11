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
}

///|
let state : WordKeysState = WordKeysState::{ separator: " ", }

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
      "separator" => ()
      _ => return -1
    }
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
        let text = @utf8.decode_lossy(r.value[0:r.value.length()])
        for token in text.split(state.separator) {
          let word = token.to_owned()
          if word.length() > 0 {
            out.push(@protocol.Record::{
              timestamp: r.timestamp,
              key: @utf8.encode(word),
              value: @utf8.encode(word),
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
