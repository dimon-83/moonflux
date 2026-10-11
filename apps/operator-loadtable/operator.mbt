// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the reference-table loader.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"key_field": "license", "value_fields": ["maker", "model"]}
//   {…, "merge": true}   partial update: fields the record does not carry
//                        keep the value they already have in the row
//
// `merge` is the reference's `row.update()` semantics: it assigns the fields
// it was given and leaves the rest of the row alone. Without it this operator
// rewrites the whole row, so a record carrying only `temperature` would drop
// `sensor`. With it, a field that is absent from the record but present in
// the stored row is carried over — and a field that is in NEITHER is refused
// by name, because there is no value to write and inventing one is worse than
// failing.
//
// For each record: the key becomes the `key_field`'s text, and the state
// value becomes a JSON object carrying `value_fields` — a table any other
// pipeline can read from the same state topic (see apps/operator-probe and
// the car example's plate check).
//
// Difference from the reference, stated rather than hidden: SDF's loader has
// no sink, so nothing about it is observable. This operator emits the record
// it loaded, so "the table is loaded" is something a stream (and a gate) can
// actually see.
//
// The state value is JSON built by hand from the selected fields. Values are
// escaped: a maker whose name contains a quote must not be able to change
// the shape of the row it lands in.

///|
priv struct LoadState {
  mut key_field : String
  mut merge : Bool
  values : Array[String]
}

///|
let state : LoadState = LoadState::{ key_field: "", merge: false, values: [], }

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
      "key_field" | "value_fields" | "merge" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "key_field") {
    Some(f) => {
      if f.length() == 0 {
        return -1
      }
      state.key_field = f
    }
    None => return -1
  }
  match cfg.get("merge") {
    None => ()
    Some(True) => state.merge = true
    Some(False) => state.merge = false
    Some(_) => return -1
  }
  match cfg.get("value_fields") {
    Some(Array(fields)) => {
      if fields.length() == 0 {
        return -1
      }
      for field in fields {
        match field {
          String(name) =>
            if name.length() == 0 {
              return -1
            } else {
              state.values.push(name)
            }
          _ => return -1
        }
      }
    }
    _ => return -1
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "loadtable",
    process: fn(_records) {
      Err(
        "this operator writes state: it is called through mf_op_state_apply (ABI v3), not mf_op_process",
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
  let loader = @sdk.GuestStatefulOperator::{
    name: "loadtable",
    process: fn(state_in, records) {
      // the CURRENT row per key: the state the host handed over, updated by
      // the records of this batch as they are processed. A later record in
      // the same batch must see the row an earlier one built — that is what
      // a partial update means, and the host's state input alone cannot show
      // it (it is the batch's opening snapshot; measured while gating merge:
      // the first partial record was refused because `sensor` existed only in
      // a row this same batch had written a moment earlier).
      let rows : Map[String, Bytes] = {}
      let order : Array[String] = []
      for e in state_in {
        let k = match (try? @utf8.decode(e.key[0:e.key.length()])) {
          Ok(text) => text
          Err(_) => return Err("state key is not UTF-8 text")
        }
        rows[k] = e.value
      }
      let out : Array[@protocol.Record] = []
      for r in records {
        // the key extraction is deliberately the same shape as
        // operator-keyfield's: a numeric id is stringified, not refused.
        // State keys are text by contract (the host refuses non-UTF-8), but
        // "the key is a number in the JSON" is a fact about the data, not a
        // reason to reject the record (found while porting the update-state
        // primitive, whose sample data keys by a numeric `id`).
        let key = match @sdk.json_field(r.value, state.key_field) {
          Ok(Some(@sdk.ScalarText(text))) => text
          Ok(Some(@sdk.ScalarNumber(d))) => {
            let n = d.to_int64()
            if n.to_double() == d {
              n.to_string()
            } else {
              return Err(
                "key field \{state.key_field} is not an integer (\{d}); keys are text",
              )
            }
          }
          Ok(Some(@sdk.ScalarBool(b))) => b.to_string()
          Ok(Some(@sdk.ScalarNull)) =>
            return Err("key field \{state.key_field} is null")
          Ok(None) => return Err("key field \{state.key_field} is missing")
          Err(e) => return Err(e)
        }
        let row = StringBuilder::new()
        row.write_string("{")
        let mut first = true
        for field in state.values {
          if !first {
            row.write_string(",")
          }
          first = false
          row.write_string("\"")
          row.write_string(json_escape(field))
          row.write_string("\":")
          let from_record = @sdk.json_field(r.value, field)
          match from_record {
            Ok(Some(@sdk.ScalarText(text))) => {
              row.write_string("\"")
              row.write_string(json_escape(text))
              row.write_string("\"")
            }
            Ok(Some(@sdk.ScalarNumber(d))) => {
              let n = d.to_int64()
              if n.to_double() == d {
                row.write_string(n.to_string())
              } else {
                row.write_string(d.to_string())
              }
            }
            Ok(Some(@sdk.ScalarBool(b))) => row.write_string(b.to_string())
            Ok(Some(@sdk.ScalarNull)) => row.write_string("null")
            Ok(None) => {
              // merging: the field keeps whatever the stored row says. A
              // field that is in neither is refused — a partial update with
              // nothing to update is a mistake, not a default.
              let carried = if state.merge {
                match rows.get(key) {
                  Some(old) => @sdk.json_field(old, field)
                  None => Ok(None)
                }
              } else {
                Ok(None)
              }
              match carried {
                Ok(Some(@sdk.ScalarText(text))) => {
                  row.write_string("\"")
                  row.write_string(json_escape(text))
                  row.write_string("\"")
                }
                Ok(Some(@sdk.ScalarNumber(d))) => {
                  let n = d.to_int64()
                  if n.to_double() == d {
                    row.write_string(n.to_string())
                  } else {
                    row.write_string(d.to_string())
                  }
                }
                Ok(Some(@sdk.ScalarBool(b))) => row.write_string(b.to_string())
                Ok(Some(@sdk.ScalarNull)) => row.write_string("null")
                Ok(None) => {
                  if state.merge {
                    return Err(
                      "value field \{field} is in neither the record nor the stored row for key \{key}",
                    )
                  }
                  return Err(
                    "value field \{field} is missing from the record for key \{key}",
                  )
                }
                Err(e) => return Err(e)
              }
            }
            Err(e) => return Err(e)
          }
        }
        row.write_string("}")
        let encoded = @utf8.encode(row.to_string())
        if !rows.contains(key) {
          order.push(key)
        }
        rows[key] = encoded
        out.push(r)
      }
      // one write per key: the batch is a transaction, and the last row for
      // a key in it is the row that survives
      let updates : Array[@operator.StateEntry] = []
      for k in order {
        let value = match rows.get(k) {
          Some(value) => value
          None => continue
        }
        updates.push(@operator.StateEntry::{ key: @utf8.encode(k), value, })
      }
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(loader, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
