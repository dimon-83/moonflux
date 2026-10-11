// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the notification builder.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"title_field": "title", "link_field": "link"}
//
// Input: records keyed by a WORD of an article title whose value is the
// article (the reference expands the title with a flat-map first).
// State: for that word, the comma-separated subscriber list.
// Output: one record per subscriber:
//   {"email":…,"word":…,"link":…,"title":…}
//
// READ-ONLY: it returns no state updates. A matcher that wrote would let a
// reader of the subscription table edit it, which is the same rule the
// stolen-plate check follows.
//
// A word nobody subscribed to produces nothing (the reference's `None`), and
// so does a word whose list is empty — "no subscribers" and "not subscribed"
// are the same answer to a notification.

///|
priv struct NotifyState {
  mut title_field : String
  mut link_field : String
}

///|
let state : NotifyState = NotifyState::{
  title_field: "title",
  link_field: "link",
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
fn text_field(value : Bytes, field : String) -> Result[String, String] {
  match @sdk.json_field(value, field) {
    Ok(Some(@sdk.ScalarText(text))) => Ok(text)
    Ok(Some(_)) => Err("field \{field} is not text")
    Ok(None) => Err("field \{field} is missing")
    Err(e) => Err(e)
  }
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
      "title_field" | "link_field" => ()
      _ => return -1
    }
  }
  for pair in [("title_field", "title"), ("link_field", "link")] {
    match cfg.get(pair.0) {
      None => ()
      Some(_) =>
        match @sdk.config_string(cfg, pair.0) {
          Some(text) =>
            if text.length() == 0 {
              return -1
            } else if pair.0 == "title_field" {
              state.title_field = text
            } else {
              state.link_field = text
            }
          None => return -1
        }
    }
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "notify",
    process: fn(_records) {
      Err(
        "this operator reads state: it is called through mf_op_state_apply (ABI v3), not mf_op_process",
      )
    },
  }
  let _ = @sdk.run_buffered(refusing, input)
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
pub fn mf_op_state_abi_version() -> Int {
  @sdk.state_abi_version()
}

///|
pub fn mf_op_state_apply(input : Bytes) -> Bytes {
  let notify = @sdk.GuestStatefulOperator::{
    name: "notify",
    process: fn(state_in, records) {
      let lists : Map[String, String] = {}
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let v = match (try? @utf8.decode(e.value[0:e.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value is not UTF-8 text")
        }
        lists[k] = v
      }
      let out : Array[@protocol.Record] = []
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "a notification needs a key on every record (the title word)",
          )
        }
        let word = @utf8.decode_lossy(r.key[0:r.key.length()])
        let list = match lists.get(word) {
          Some(list) => list
          None => continue
        }
        if list == "" {
          continue
        }
        let title = match text_field(r.value, state.title_field) {
          Ok(text) => text
          Err(e) => return Err(e)
        }
        let link = match text_field(r.value, state.link_field) {
          Ok(text) => text
          Err(e) => return Err(e)
        }
        for piece in list.split(",") {
          let email = piece.to_owned()
          if email == "" {
            continue
          }
          let event = "{\"email\":\"" +
            json_escape(email) +
            "\",\"word\":\"" +
            json_escape(word) +
            "\",\"link\":\"" +
            json_escape(link) +
            "\",\"title\":\"" +
            json_escape(title) +
            "\"}"
          out.push(@protocol.Record::{
            timestamp: r.timestamp,
            key: r.key,
            value: @utf8.encode(event),
            headers: r.headers,
          })
        }
      }
      let none : Array[@operator.StateEntry] = []
      Ok((none, out))
    },
  }
  let _ = @sdk.run_stateful(notify, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
