// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the account-balance operator.
//
// Config (through mf_op_init; unknown keys are refused):
//   {}                    apply each record's delta and write the balance back
//   {"commit": false}     derive the same balances but write nothing
//
// Input: records keyed by iban whose value is
//   {"iban":X,"delta":N,"txid":T,"operation":"CreditAccount"|"DebitAccount"}
// (what apps/operator-bankevents emits).
//
// Output: one record per input record:
//   {"iban":X,"balance":N,"delta":N,"operation":"...","txid":T,"overdraft":b}
//
// The state value is the balance's decimal text. `overdraft` is computed
// from the post-event balance, so the same stream answers "who is in the
// red" without a second pass — the reference sends those to an `overdraft`
// topic instead, and a pipeline that reads this one and keeps the flagged
// records is the same set of events (see the example).
//
// `commit: false` is for exactly that second reader: it derives the same
// running balances from the writer's state topic without writing, so two
// pipelines can share one state topic without double-applying every event.
// A reader that wrote would silently double every balance.
//
// Balances are integers, like the sample data's amounts: a fractional delta
// is refused rather than rounded, and so is a state value this operator
// cannot parse (a state entry that is not a balance is a corrupted key, not
// a zero).

///|
priv struct BalanceState {
  mut commit : Bool
}

///|
let state : BalanceState = BalanceState::{ commit: true, }

///|
/// Reads one integer field out of a delta record's JSON value.
fn delta_of(value : Bytes) -> Result[(String, Int, String, String), String] {
  let text = @utf8.decode_lossy(value[0:value.length()])
  let parsed = match (try? @json.parse(text)) {
    Ok(json) => json
    Err(_) => return Err("balance record is not JSON")
  }
  let obj = match parsed {
    Object(obj) => obj
    _ => return Err("balance record is not a JSON object")
  }
  let iban = match obj.get("iban") {
    Some(String(s)) => s
    _ => return Err("balance record has no iban")
  }
  let delta = match obj.get("delta") {
    Some(Number(d)) => {
      let n = d.to_int64()
      if n.to_double() != d {
        return Err(
          "delta is not an integer (\{d}); this operator refuses to round money",
        )
      }
      n.to_int()
    }
    _ => return Err("balance record has no numeric delta")
  }
  let operation = match obj.get("operation") {
    Some(String(s)) => s
    _ => "Unknown"
  }
  let txid = match obj.get("txid") {
    Some(String(s)) => s
    _ => ""
  }
  Ok((iban, delta, operation, txid))
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
      "commit" => ()
      _ => return -1
    }
  }
  match cfg.get("commit") {
    Some(True) => state.commit = true
    Some(False) => state.commit = false
    Some(_) => return -1
    None => ()
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "balance",
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
  let balance = @sdk.GuestStatefulOperator::{
    name: "balance",
    process: fn(state_in, records) {
      let balances : Map[String, Int] = {}
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        let v = match (try? @utf8.decode(e.value[0:e.value.length()])) {
          Ok(text) => text
          Err(_) => return Err("state value is not UTF-8 text")
        }
        balances[k] = match (try? @string.parse_int(v)) {
          Ok(n) => n
          Err(_) => return Err("state for \{k} is not a balance (\{v})")
        }
      }
      let out : Array[@protocol.Record] = []
      let updates : Array[@operator.StateEntry] = []
      for r in records {
        let (iban, delta, operation, txid) = match delta_of(r.value) {
          Ok(parts) => parts
          Err(e) => return Err(e)
        }
        if r.key.length() > 0 {
          let record_key = @utf8.decode_lossy(r.key[0:r.key.length()])
          if record_key != iban {
            return Err(
              "record key \{record_key} does not match its iban \{iban}",
            )
          }
        }
        let current = match balances.get(iban) {
          Some(n) => n
          None => 0
        }
        let next = current + delta
        balances[iban] = next
        let overdraft = next < 0
        let answer = "{\"iban\":\"" +
          iban +
          "\",\"balance\":" +
          next.to_string() +
          ",\"delta\":" +
          delta.to_string() +
          ",\"operation\":\"" +
          operation +
          "\",\"txid\":\"" +
          txid +
          "\",\"overdraft\":" +
          (if overdraft { "true" } else { "false" }) +
          "}"
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key: r.key,
          value: @utf8.encode(answer),
          headers: r.headers,
        })
        if state.commit {
          updates.push(@operator.StateEntry::{
            key: @utf8.encode(iban),
            value: @utf8.encode(next.to_string()),
          })
        }
      }
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(balance, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
