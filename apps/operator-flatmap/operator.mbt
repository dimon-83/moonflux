// SPDX-License-Identifier: Apache-2.0
// apps/operator-flatmap: a config-driven 1 -> N operator (wasm guest).
//
// Why this module exists: SDF's `flat-map` primitive turns one input
// record into many (split a sentence into words). Nothing in an mbel
// expression can do that — a rule returns exactly one string per record
// — so the fan-out belongs to the batch operator, whose contract is
// `Array[Record] -> Array[Record]` and therefore already allows N out.
//
// Config (through mf_op_init; the host never interprets it):
//   {}                        split on a single space
//   {"separator": ","}        split on that exact separator
// Empty tokens are dropped (a trailing separator is not a record), and
// each emitted record keeps the source record's key, timestamp and
// headers — the tokens are fragments of one event, not new events.
//
// Offsets are the host's business: the guest never sees them (decision
// 15). On the ingress path the sink sees the tokens in order; on the
// serve/fetch path each source entry is chained individually, so the
// fan-out siblings share their source offset and the reply framing
// starts a new frame for each (P18) — a reader walking offsets sees the
// duplicate on purpose rather than a silently renumbered stream.

///|
priv struct FlatmapState {
  mut separator : String
}

///|
let state : FlatmapState = FlatmapState::{ separator: " ", }

///|
pub fn mf_op_abi_version() -> Int {
  @sdk.abi_version()
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
        // an empty separator has no defined split: refusing it here is
        // cheaper than whatever String::split would do with it
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
let op : @sdk.GuestOperator = @sdk.GuestOperator::{
  name: "flatmap",
  process: fn(records) {
    let out : Array[@protocol.Record] = []
    for r in records {
      let value = @utf8.decode_lossy(r.value[0:r.value.length()])
      for piece in value.split(state.separator) {
        let token = piece.to_owned()
        if token.length() > 0 {
          out.push(@protocol.Record::{
            timestamp: r.timestamp,
            key: r.key,
            value: @utf8.encode(token),
            headers: r.headers,
          })
        }
      }
    }
    Ok(out)
  },
}

///|
pub fn mf_op_alloc_input(len : Int) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let _ = @sdk.run_buffered(op, input)
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
