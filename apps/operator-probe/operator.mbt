// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the read-only state probe.
//
// Config (through mf_op_init; unknown keys are refused):
//   {}                     look up each record's key
//   {"missing": 0}         the count to report for a key the state never saw
//
// The operator answers with a JSON object per record and **returns no state
// updates at all** — a probe that wrote would turn a read into a write, and
// two pipelines sharing a state topic must not be able to fight over it by
// accident. The host does not need to know: an empty update list is a valid
// answer.
//
// Honest boundary: the state a probe sees is the host's VIEW, rebuilt when
// the probe process starts and updated only by this process's own writes.
// A long-running probe therefore answers from a snapshot — it does not tail
// another process's writes. The example that uses this operator says so.

///|
priv struct ProbeState {
  mut missing : Int
}

///|
let state : ProbeState = ProbeState::{ missing: 0, }

///|
/// A minimal JSON string escape: the key is data, and a quote or backslash
/// in it must not be able to change the shape of the answer.
fn json_string(text : String) -> String {
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
      "missing" => ()
      _ => return -1
    }
  }
  let missing = match cfg.get("missing") {
    None => None
    Some(_) => @sdk.config_int(cfg, "missing")
  }
  match missing {
    Some(n) => {
      if n < 0 {
        return -1
      }
      state.missing = n
    }
    None => ()
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "probe",
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
  let probe = @sdk.GuestStatefulOperator::{
    name: "probe",
    process: fn(state_in, records) {
      let counts : Map[String, Int] = {}
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let v = match (try? @utf8.decode(e.value[0:e.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value is not UTF-8 text")
        }
        counts[k] = match (try? @string.parse_int(v)) {
          Ok(n) => n
          Err(_) => state.missing
        }
      }
      let out : Array[@protocol.Record] = []
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "a probe needs a key on every record (the word to look up)",
          )
        }
        let word = match (try? @utf8.decode(r.key[0:r.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("record key is not UTF-8 text")
        }
        let count = match counts.get(word) {
          Some(n) => n
          None => state.missing
        }
        let answer = "{\"word\":\"" +
          json_string(word) +
          "\",\"count\":" +
          count.to_string() +
          "}"
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value: @utf8.encode(answer),
          headers: r.headers,
        })
      }
      // no updates: a probe reads
      let none : Array[@operator.StateEntry] = []
      Ok((none, out))
    },
  }
  let _ = @sdk.run_stateful(probe, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
