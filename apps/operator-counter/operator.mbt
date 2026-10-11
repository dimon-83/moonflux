// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the keyed counter.
//
// Why this module exists: SDF's `states:` + `update-state` primitives are
// services that mutate a keyed state object per event. moonflux has no
// state object; what it has is a *state topic* (a compacted keyed log) and
// a host that caches it. This operator is the guest half of that: the host
// hands it the current state entries for the keys in this batch, the guest
// returns the batches it wants to emit and the state to write back.
//
// Config (through mf_op_init; unknown keys are refused):
//   {}   count every key's occurrences, emitting the running total
//
// Every record must carry a key: a counter with nothing to count by is a
// mistake, and it is refused by name rather than silently collapsing all
// records into one counter.
//
// The batch is one transaction: every record in it sees the state as it
// was when the batch arrived, so replaying a batch is deterministic.

///|
/// One counter step: reads the values it was handed, adds one per record
/// for that record's key, and returns both the emitted records and the
/// state the host should keep.
fn counter() -> @sdk.GuestStatefulOperator {
  @sdk.GuestStatefulOperator::{
    name: "counter",
    process: fn(state, records) {
      let seen : Map[String, Int] = {}
      for e in state {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let v = match (try? @utf8.decode(e.value[0:e.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value is not UTF-8 text")
        }
        seen[k] = match (try? @string.parse_int(v)) {
          Ok(n) => n
          Err(_) => 0
        }
      }
      let out : Array[@protocol.Record] = []
      // one state write per key, not per record: the host applies entries
      // in order and the last write wins, so emitting every intermediate
      // value would be write amplification with no reader
      let order : Array[String] = []
      let latest : Map[String, Bytes] = {}
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "a counter needs a key on every record (produce --key or a key-setting operator)",
          )
        }
        let k = match (try? @utf8.decode(r.key[0:r.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("record key is not UTF-8 text")
        }
        let next = (match seen.get(k) {
            Some(n) => n
            None => 0
          }) +
          1
        seen[k] = next
        let value = @utf8.encode(next.to_string())
        if !latest.contains(k) {
          order.push(k)
        }
        latest[k] = value
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value,
          headers: r.headers,
        })
      }
      let updates : Array[@operator.StateEntry] = []
      for k in order {
        let value = match latest.get(k) {
          Some(v) => v
          None => b""
        }
        updates.push(@operator.StateEntry::{ key: @utf8.encode(k), value, })
      }
      Ok((updates, out))
    },
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
  match @sdk.parse_config(config) {
    Ok(cfg) =>
      if cfg.length() == 0 {
        0
      } else {
        // the only honest config today is "{}": anything else asks for a
        // behavior this operator does not have
        -1
      }
    Err(_) => -1
  }
}

///|
/// The batch entry point exists because every ABI v1 module has it, but a
/// stateful operator must not silently run stateless: this refuses, by
/// name, and the host picks mf_op_state_apply from the v3 pair instead.
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "counter",
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
  let _ = @sdk.run_stateful(counter(), input)
  @sdk.buffered_output()
}

///|
/// The executable-package stub: a wasm guest has no entry point the host
/// calls, so main only has to exist (the same shape every operator module
/// in this repository uses).
fn main {
  let _ = mf_op_state_abi_version()
}
