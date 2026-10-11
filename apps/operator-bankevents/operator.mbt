// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the bank-event normalizer.
//
// Input: the reference example's admin/business events as JSON, one per
// record:
//   {"iban":X, "timestamp":T, "operation":{"AddAccount":{"amount":N,...}}}
//   {"txid":T, "operation":{"Deposit":{"amount":N,"iban":X,...}}}
//   {"txid":T, "operation":{"Withdrawal":{"amount":N,"iban":X,...}}}
//   {"txid":T, "operation":{"Transfer":{"amount":N,
//        "sender":{"iban":S},"beneficiary":{"iban":B}}}}
//
// Output: one record per affected account, keyed by its iban:
//   {"iban":X,"delta":N,"txid":T,"operation":"CreditAccount"|"DebitAccount"}
//
// A transfer emits two records (debit the sender, credit the beneficiary).
// That is the whole point: the state layer fetches state per record key, so
// one event that moves money between two accounts has to become two keyed
// records or one of the two balances would be computed from nothing.
//
// Amounts are integers, as in the reference sample data. A fractional amount
// is refused by name rather than rounded: silently dropping cents from a
// ledger is not a rounding decision an operator gets to make.

///|
/// Reads the signed amount of an operation object, or a named refusal.
fn amount_of(obj : Map[String, Json], path : String) -> Result[Int, String] {
  match obj.get("amount") {
    Some(Number(d)) => {
      let n = d.to_int64()
      let as_float = n.to_double()
      if as_float != d {
        Err(
          "\{path}.amount is not an integer (\{d}); this operator refuses to round money",
        )
      } else {
        Ok(n.to_int())
      }
    }
    Some(_) => Err("\{path}.amount is not a number")
    None => Err("\{path}.amount is missing")
  }
}

///|
fn text_of(obj : Map[String, Json], field : String) -> String? {
  match obj.get(field) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Builds one output record: the delta applied to `iban`.
fn delta_record(
  iban : String,
  delta : Int,
  operation : String,
  txid : String,
  timestamp : String,
) -> @protocol.Record {
  let value = "{\"iban\":\"" +
    iban +
    "\",\"delta\":" +
    delta.to_string() +
    ",\"operation\":\"" +
    operation +
    "\",\"txid\":\"" +
    txid +
    "\",\"timestamp\":\"" +
    timestamp +
    "\"}"
  @protocol.Record::{
    timestamp: 0L,
    key: @utf8.encode(iban),
    value: @utf8.encode(value),
    headers: [],
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
    Ok(cfg) => if cfg.length() == 0 { 0 } else { -1 }
    Err(_) => -1
  }
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let normalizer = @sdk.GuestOperator::{
    name: "bankevents",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let text = @utf8.decode_lossy(r.value[0:r.value.length()])
        let parsed = match (try? @json.parse(text)) {
          Ok(json) => json
          Err(_) => return Err("bank event is not JSON")
        }
        let event = match parsed {
          Object(obj) => obj
          _ => return Err("bank event is not a JSON object")
        }
        let operation = match event.get("operation") {
          Some(Object(op)) => op
          Some(_) => return Err("bank event operation is not an object")
          None => return Err("bank event has no operation")
        }
        let timestamp = match text_of(event, "timestamp") {
          Some(t) => t
          None => ""
        }
        // the operation object has exactly one member, and its name is the
        // operation kind (the reference's enum encoding)
        for kind in operation.keys() {
          let body = match operation.get(kind) {
            Some(Object(b)) => b
            _ => return Err("operation \{kind} is not an object")
          }
          match kind {
            "AddAccount" | "Deposit" => {
              let iban = match text_of(body, "iban") {
                Some(iban) => iban
                None =>
                  // AddAccount carries the iban at the event's top level
                  match text_of(event, "iban") {
                    Some(iban) => iban
                    None => return Err("\{kind} has no iban")
                  }
              }
              let amount = match amount_of(body, kind) {
                Ok(n) => n
                Err(e) => return Err(e)
              }
              let txid = match text_of(event, "txid") {
                Some(t) => t
                None => ""
              }
              out.push(
                delta_record(iban, amount, "CreditAccount", txid, timestamp),
              )
            }
            "Withdrawal" => {
              let iban = match text_of(body, "iban") {
                Some(iban) => iban
                None => return Err("Withdrawal has no iban")
              }
              let amount = match amount_of(body, "Withdrawal") {
                Ok(n) => n
                Err(e) => return Err(e)
              }
              let txid = match text_of(event, "txid") {
                Some(t) => t
                None => ""
              }
              out.push(
                delta_record(iban, -amount, "DebitAccount", txid, timestamp),
              )
            }
            "Transfer" => {
              let amount = match amount_of(body, "Transfer") {
                Ok(n) => n
                Err(e) => return Err(e)
              }
              let txid = match text_of(event, "txid") {
                Some(t) => t
                None => ""
              }
              let sender = match body.get("sender") {
                Some(Object(s)) => s
                _ => return Err("Transfer has no sender")
              }
              let beneficiary = match body.get("beneficiary") {
                Some(Object(b)) => b
                _ => return Err("Transfer has no beneficiary")
              }
              let from = match text_of(sender, "iban") {
                Some(iban) => iban
                None => return Err("Transfer sender has no iban")
              }
              let to = match text_of(beneficiary, "iban") {
                Some(iban) => iban
                None => return Err("Transfer beneficiary has no iban")
              }
              // two records, one key each: debit the sender, credit the
              // beneficiary, in that order (the reference's debit then credit)
              out.push(
                delta_record(from, -amount, "DebitAccount", txid, timestamp),
              )
              out.push(
                delta_record(to, amount, "CreditAccount", txid, timestamp),
              )
            }
            other => return Err("unknown bank operation \{other}")
          }
        }
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(normalizer, input)
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
