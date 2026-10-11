// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the subscriber-table builder.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"email_field": "email"}
//
// Input: records keyed by the watched word whose value carries the email.
// State: for that key, a comma-separated list of distinct emails (the
// reference's `email-list`).
//
// The dedup is the whole point of keeping the list: the same person asking
// twice must not be notified twice, and "already there" is a fact the state
// has and a stateless appender does not. It is also why this is a writer and
// not something a reader can emulate.
//
// Commas cannot appear inside an email address, which is what makes a
// comma-separated list a safe carrier here — the same judgement the reference
// makes.

///|
priv struct SubscribeState {
  mut email_field : String
}

///|
let state : SubscribeState = SubscribeState::{ email_field: "", }

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
      "email_field" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "email_field") {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.email_field = text
    }
    None => return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "subscribe",
    process: fn(_records) {
      Err(
        "this operator keeps state: it is called through mf_op_state_apply (ABI v3), not mf_op_process",
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
  let subscribe = @sdk.GuestStatefulOperator::{
    name: "subscribe",
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
      let order : Array[String] = []
      let out : Array[@protocol.Record] = []
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "a subscription needs a key on every record (the watched word)",
          )
        }
        let word = @utf8.decode_lossy(r.key[0:r.key.length()])
        let email = match @sdk.json_field(r.value, state.email_field) {
          Ok(Some(@sdk.ScalarText(text))) => text
          Ok(Some(_)) =>
            return Err("email field \{state.email_field} is not text")
          Ok(None) =>
            return Err(
              "email field \{state.email_field} is missing for word \{word}",
            )
          Err(e) => return Err(e)
        }
        if email.contains(",") {
          return Err(
            "email \{email} contains a comma, which is the list separator",
          )
        }
        let current = match lists.get(word) {
          Some(list) => list
          None => {
            order.push(word)
            ""
          }
        }
        // already subscribed: the state does not change, and the record still
        // comes out (the loader is observable, like the other table loaders)
        if !is_subscribed(current, email) {
          lists[word] = if current == "" {
            email
          } else {
            current + "," + email
          }
        }
        out.push(r)
      }
      let updates : Array[@operator.StateEntry] = []
      for k in order {
        let list = match lists.get(k) {
          Some(list) => list
          None => ""
        }
        updates.push(@operator.StateEntry::{
          key: @utf8.encode(k),
          value: @utf8.encode(list),
        })
      }
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(subscribe, input)
  @sdk.buffered_output()
}

///|
/// True when `email` is already in a comma-separated list.
fn is_subscribed(list : String, email : String) -> Bool {
  if list == "" {
    return false
  }
  for part in list.split(",") {
    if part.to_owned() == email {
      return true
    }
  }
  false
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
