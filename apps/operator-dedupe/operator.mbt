// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the dedupe operator.
//
// Config: `{}` — everything it needs is the record's key.
//
// Input: records keyed by the dimension to deduplicate on (set the key with
// operator-keyfield, or make the window part of it with operator-tumble).
// Output: the FIRST record for each key passes; later ones are dropped, which
// in this platform's operator contract is simply a shorter batch (1 -> 0),
// the same shape operator-filter has.
//
// State: one entry per seen key, value `1`. A reader can therefore see the
// dedupe horizon by looking at the state topic — including whether it is
// unbounded, which is the honest way to notice that this operator's memory
// grows with distinct keys.

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
    Ok(cfg) => if cfg.length() == 0 { 0 } else { -1 }
    Err(_) => -1
  }
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "dedupe",
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
  let dedupe = @sdk.GuestStatefulOperator::{
    name: "dedupe",
    process: fn(state_in, records) {
      // keys the host says we have already seen
      let seen : Map[String, Bool] = {}
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        seen[k] = true
      }
      let out : Array[@protocol.Record] = []
      let updates : Array[@operator.StateEntry] = []
      for r in records {
        if r.key.length() == 0 {
          return Err(
            "dedupe needs a key on every record: the key IS the deduplication dimension (set it with operator-keyfield, or make a window part of it with operator-tumble)",
          )
        }
        let k = match (try? @utf8.decode(r.key[0:r.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("record key is not UTF-8 text")
        }
        match seen.get(k) {
          // already seen: the record does not pass, exactly like a filter
          Some(_) => ()
          None => {
            seen[k] = true
            updates.push(@operator.StateEntry::{
              key: @utf8.encode(k),
              value: @utf8.encode("1"),
            })
            out.push(r)
          }
        }
      }
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(dedupe, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
