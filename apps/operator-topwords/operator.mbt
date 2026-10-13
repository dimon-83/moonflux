// SPDX-License-Identifier: Apache-2.0
// ABI v1 + v3 surface of the windowed top-N flush.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"sentence_field": "sentence", "time_field": "tst", "window_ms": 20000}
//   {…, "top": 3, "separator": " ", "lowercase": true,
//        "time_format": "epoch_ms" | "iso8601"}
//
// Input: records whose value carries a sentence and an event time (the
// constant-key operator is what makes the accumulator global — see
// apps/operator-keyconst).
//
// State for that ONE key: `<window_start>;<word>:<count>;<word>:<count>…`
//
// Output: `{"window_start":W,"top_words":[{"word":…,"count":…},…]}` — emitted
// ONLY when a record arrives that belongs to a LATER window, i.e. when the
// window closes. Records inside the current window emit nothing, which is
// what "flush on close" means.
//
// The encoding is text rather than nested JSON on purpose: the guest SDK can
// read one top-level JSON scalar cheaply but has no nested-object reader, and
// words here are already filtered to alphanumerics (the reference does the
// same), so `;` and `:` cannot occur inside one. The operator refuses a word
// that would break the encoding instead of writing a state value it cannot
// read back.
//
// Determinism: ties are broken by word ascending, so the same input always
// yields the same top-N. A late record (a window at or before the current
// one) is REFUSED by name: the reference's watermark drops it silently, and
// silently dropping data is the one thing this repository will not do.

///|
priv struct TopWordsState {
  mut sentence_field : String
  mut time_field : String
  mut window_ms : Int64
  mut top : Int32
  mut separator : String
  mut lowercase : Bool
  mut time_format : String
}

///|
let state : TopWordsState = TopWordsState::{
  sentence_field: "",
  time_field: "",
  window_ms: 0L,
  top: 3,
  separator: " ",
  lowercase: true,
  time_format: "epoch_ms",
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
fn is_alnum(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

///|
/// Splits a sentence the way the reference does: whitespace-separated words,
/// each filtered down to its alphanumeric characters, empty ones dropped.
fn words_of(
  sentence : String,
  separator : String,
  lowercase : Bool,
) -> Array[String] {
  let out : Array[String] = []
  for piece in sentence.split(separator) {
    let sb = StringBuilder::new()
    for ch in piece {
      if is_alnum(ch) {
        sb.write_char(ch)
      }
    }
    // lowercasing happens on the whole word: String::to_lower is the
    // operation the other operators use, and one place for it is enough
    let word = if lowercase {
      sb.to_string().to_lower()
    } else {
      sb.to_string()
    }
    if word.length() > 0 {
      out.push(word)
    }
  }
  out
}

///|
/// Parses `<window>;<word>:<count>;…` into (window, words, counts).
fn parse_accumulator(
  text : String,
) -> Result[(Int64, Array[String], Array[Int32]), String] {
  let mut window = 0L
  let words : Array[String] = []
  let counts : Array[Int32] = []
  if text == "" {
    return Ok((window, words, counts))
  }
  let mut part = 0
  for piece in text.split(";") {
    let chunk = piece.to_owned()
    part = part + 1
    if part == 1 {
      window = match (try? @string.parse_int(chunk)) {
        Ok(n) => n.to_int64()
        Err(_) =>
          return Err("accumulator header is not a window start (\{chunk})")
      }
      continue
    }
    let colon = match chunk.find(":") {
      Some(at) => at
      None => return Err("accumulator entry has no count (\{chunk})")
    }
    let word = chunk[0:colon].to_owned()
    let count_text = chunk[colon + 1:chunk.length()].to_owned()
    let count = match (try? @string.parse_int(count_text)) {
      Ok(n) => n
      Err(_) => return Err("accumulator count is not a number (\{count_text})")
    }
    words.push(word)
    counts.push(count)
  }
  Ok((window, words, counts))
}

///|
/// Sorts (word, count) pairs by count descending, then word ascending, and
/// renders the top `top` as a JSON array.
fn render_top(
  words : Array[String],
  counts : Array[Int32],
  top : Int32,
) -> String {
  let n = words.length()
  // an index sort keeps this readable without a tuple-comparison helper
  let order : Array[Int32] = []
  for i in 0..<n {
    order.push(i)
  }
  // insertion sort: windows hold a handful of distinct words, and the
  // ordering must be total (count desc, word asc) for determinism
  for i in 1..<n {
    let key = order[i]
    let mut j = i
    while j > 0 {
      let prev = order[j - 1]
      let swap = if counts[prev] < counts[key] {
        true
      } else if counts[prev] > counts[key] {
        false
      } else {
        words[prev] > words[key]
      }
      if !swap {
        break
      }
      order[j] = prev
      j = j - 1
    }
    order[j] = key
  }
  let out = StringBuilder::new()
  out.write_string("[")
  let limit = if top < n { top } else { n }
  for k in 0..<limit {
    let idx = order[k]
    if k > 0 {
      out.write_string(",")
    }
    out.write_string("{\"word\":\"")
    out.write_string(json_escape(words[idx]))
    out.write_string("\",\"count\":")
    out.write_string(counts[idx].to_string())
    out.write_string("}")
  }
  out.write_string("]")
  out.to_string()
}

///|
fn event_time(value : Bytes) -> Result[Int64, String] {
  if state.time_format == "iso8601" {
    return match @sdk.json_field(value, state.time_field) {
      Ok(Some(@sdk.ScalarText(text))) => @sdk.parse_iso8601_ms(text)
      Ok(Some(_)) => Err("field \{state.time_field} is not ISO-8601 text")
      Ok(None) => Err("field \{state.time_field} is missing")
      Err(e) => Err(e)
    }
  }
  match @sdk.json_field(value, state.time_field) {
    Ok(Some(@sdk.ScalarNumber(d))) => {
      let n = d.to_int64()
      if n.to_double() == d {
        Ok(n)
      } else {
        Err("field \{state.time_field} is not whole milliseconds")
      }
    }
    Ok(Some(_)) => Err("field \{state.time_field} is not a number")
    Ok(None) => Err("field \{state.time_field} is missing")
    Err(e) => Err(e)
  }
}

///|
pub fn mf_op_abi_version() -> Int32 {
  @sdk.abi_version()
}

///|
pub fn mf_op_alloc_input(len : Int32) -> Bytes {
  @sdk.alloc_input(len)
}

///|
pub fn mf_op_init(config : Bytes) -> Int32 {
  let cfg = match @sdk.parse_config(config) {
    Ok(cfg) => cfg
    Err(_) => return -1
  }
  for key in cfg.keys() {
    match key {
      "sentence_field"
      | "time_field"
      | "window_ms"
      | "top"
      | "separator"
      | "lowercase"
      | "time_format" => ()
      _ => return -1
    }
  }
  match @sdk.config_string(cfg, "sentence_field") {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.sentence_field = text
    }
    None => return -1
  }
  match @sdk.config_string(cfg, "time_field") {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.time_field = text
    }
    None => return -1
  }
  match @sdk.config_int(cfg, "window_ms") {
    Some(ms) => {
      if ms <= 0 {
        return -1
      }
      state.window_ms = ms.to_int64()
    }
    None => return -1
  }
  match cfg.get("top") {
    None => ()
    Some(_) =>
      match @sdk.config_int(cfg, "top") {
        Some(n) => {
          if n <= 0 {
            return -1
          }
          state.top = n
        }
        None => return -1
      }
  }
  match cfg.get("separator") {
    None => ()
    Some(_) =>
      match @sdk.config_string(cfg, "separator") {
        Some(text) => {
          if text.length() == 0 {
            return -1
          }
          state.separator = text
        }
        None => return -1
      }
  }
  match cfg.get("lowercase") {
    None => ()
    Some(True) => state.lowercase = true
    Some(False) => state.lowercase = false
    Some(_) => return -1
  }
  match cfg.get("time_format") {
    None => ()
    Some(_) =>
      match @sdk.config_string(cfg, "time_format") {
        Some(text) =>
          match text {
            "epoch_ms" | "iso8601" => state.time_format = text
            _ => return -1
          }
        None => return -1
      }
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let refusing = @sdk.GuestOperator::{
    name: "topwords",
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
pub fn mf_op_output_len() -> Int32 {
  @sdk.output_len()
}

///|
pub fn mf_op_last_status() -> Int32 {
  @sdk.last_status()
}

///|
pub fn mf_op_last_error() -> Bytes {
  @sdk.last_error_bytes()
}

///|
pub fn mf_op_state_abi_version() -> Int32 {
  @sdk.state_abi_version()
}

///|
pub fn mf_op_state_apply(input : Bytes) -> Bytes {
  let topwords = @sdk.GuestStatefulOperator::{
    name: "topwords",
    process: fn(state_in, records) {
      // an empty batch must not clobber the accumulator: the host hands over
      // one empty batch when a pull has nothing in it
      if records.length() == 0 {
        let none : Array[@operator.StateEntry] = []
        let no_records : Array[@protocol.Record] = []
        return Ok((none, no_records))
      }
      // the key comes from the RECORDS, not from the state: on the first
      // batch there is no state, and reading the key from it was a real bug
      // (the operator refused its own first batch)
      let key = match
        (try? @utf8.decode(records[0].key[0:records[0].key.length()])) {
        Ok(text) => text
        Err(_) => return Err("record key is not UTF-8 text")
      }
      if key == "" {
        return Err(
          "topwords needs a key on every record (use operator-keyconst for a global accumulator)",
        )
      }
      for r in records {
        let k = @utf8.decode_lossy(r.key[0:r.key.length()])
        if k != key {
          return Err(
            "topwords accumulates one window per key, but this batch carries two: a global accumulator needs one constant key (operator-keyconst)",
          )
        }
      }
      let mut window = 0L
      let mut words : Array[String] = []
      let mut counts : Array[Int32] = []
      let mut have_state = false
      for e in state_in {
        if e.value.length() > 0 {
          let text = @utf8.decode_lossy(e.value[0:e.value.length()])
          let parsed = match parse_accumulator(text) {
            Ok(parsed) => parsed
            Err(err) => return Err(err)
          }
          window = parsed.0
          words = parsed.1
          counts = parsed.2
          have_state = true
        }
      }
      let out : Array[@protocol.Record] = []
      for r in records {
        let ts = match event_time(r.value) {
          Ok(ts) => ts
          Err(e) => return Err(e)
        }
        if ts < 0L {
          return Err("topwords needs non-negative event timestamps (got \{ts})")
        }
        let w = ts / state.window_ms * state.window_ms
        let sentence = match @sdk.json_field(r.value, state.sentence_field) {
          Ok(Some(@sdk.ScalarText(text))) => text
          Ok(Some(_)) => return Err("field \{state.sentence_field} is not text")
          Ok(None) => return Err("field \{state.sentence_field} is missing")
          Err(e) => return Err(e)
        }
        let incoming = words_of(sentence, state.separator, state.lowercase)
        if have_state {
          if w < window {
            return Err(
              "late record: window \{w} is closed (the current window is \{window}); a closed window is not reopened",
            )
          }
          if w > window {
            // the window closes here, on the event that leaves it
            let summary = "{\"window_start\":" +
              window.to_string() +
              ",\"top_words\":" +
              render_top(words, counts, state.top) +
              "}"
            out.push(@protocol.Record::{
              timestamp: r.timestamp,
              key: @utf8.encode(
                if key == "" {
                  window.to_string()
                } else {
                  key
                },
              ),
              value: @utf8.encode(summary),
              headers: [],
            })
            window = w
            words = []
            counts = []
          }
        } else {
          window = w
          have_state = true
        }
        for word in incoming {
          if word.contains(";") || word.contains(":") {
            return Err("word \{word} contains the accumulator separator")
          }
          let mut found = false
          for i, existing in words {
            if existing == word {
              counts[i] = counts[i] + 1
              found = true
              break
            }
          }
          if !found {
            words.push(word)
            counts.push(1)
          }
        }
      }
      let encoded = StringBuilder::new()
      encoded.write_string(window.to_string())
      for i, word in words {
        encoded.write_string(";")
        encoded.write_string(word)
        encoded.write_string(":")
        encoded.write_string(counts[i].to_string())
      }
      let updates : Array[@operator.StateEntry] = [
        @operator.StateEntry::{
          key: @utf8.encode(key),
          value: @utf8.encode(encoded.to_string()),
        },
      ]
      Ok((updates, out))
    },
  }
  let _ = @sdk.run_stateful(topwords, input)
  @sdk.buffered_output()
}

///|
fn main {
  let _ = mf_op_state_abi_version()
}
