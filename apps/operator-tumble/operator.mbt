// SPDX-License-Identifier: Apache-2.0
// ABI v1 surface of the tumbling-window keyer.
//
// Config (through mf_op_init; unknown keys are refused):
//   {"window_ms": 60000}                       width in ms (required, > 0)
//   {"window_ms": 60000, "time_field": "ts"}   event time from the value's JSON
//   {"window_ms": 60000, "time_field": "ts", "key_field": "user"}
//   {"window_ms": 30000, "time_field": "timestamp",
//    "time_format": "iso8601"}                 ISO-8601 text instead of a number
//
// Each record's key becomes `key@<window_start>` where window_start is the
// event time floored to the width. An empty key keeps just the window
// start, which is the honest spelling of "one global window per bucket".
//
// Windowing in moonflux is not a second stateful concept: it is a KEY SHAPE.
// State is keyed by the record key, so rewriting the key makes every window
// its own state entry — which is why windows need no new ABI, no host
// support, and no timer (P30/T114, docs/operator-abi-v3-state.md §5).
//
// `time_field` exists because a file source stamps every record with one
// read-time timestamp: a data file whose rows carry their own event time is
// the normal case (the SDF examples' JSON is exactly that), and a keyer
// that could only read the log's timestamp would put a whole file in one
// window. `key_field` does the same for sources that carry the partitioning
// key inside the value instead of in the record key.
//
// What this deliberately does NOT do: there is no idle trigger and no
// processing-time advance. A window exists because a record arrived for it,
// and it stops changing when no more records arrive for it. A pipeline with
// no traffic has nothing to close — that boundary is documented rather than
// papered over with a timer (the kernel has no clock to begin with).
//
// Timestamps must be non-negative: a negative event time has no meaningful
// floor here, and refusing it by name beats a window start nobody can
// explain.

///|
priv struct TumbleState {
  mut window_ms : Int64
  /// "" = use the record's own timestamp (the log's event-time column)
  mut time_field : String
  /// "" = keep the record's key
  mut key_field : String
  /// "epoch_ms" (a number) or "iso8601" (text)
  mut time_format : String
}

///|
let state : TumbleState = TumbleState::{
  window_ms: 0L,
  time_field: "",
  key_field: "",
  time_format: "epoch_ms",
}

///|
/// Days between 1970-01-01 and `y-m-d` (Howard Hinnant's civil-days
/// algorithm). Pure integer arithmetic: parsing a date is computation, not
/// a clock read, so this stays inside the kernel's red line.
fn days_from_civil(y : Int, m : Int, d : Int) -> Int64 {
  let y2 = if m <= 2 { y - 1 } else { y }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe - 719468).to_int64()
}

///|
fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 => if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) { 29 } else { 28 }
    _ => 0
  }
}

///|
/// One character of a string as a code point, for the ASCII-level checks a
/// timestamp parser needs. `String` indexing yields the UTF-16 code unit.
fn char_u(text : String, at : Int) -> UInt {
  text.unsafe_charcode_at(at).to_uint()
}

///|
fn is_digit_u(c : UInt) -> Bool {
  c >= '0'.to_uint() && c <= '9'.to_uint()
}

///|
fn digits_at(text : String, at : Int, count : Int) -> Int? {
  if at + count > text.length() {
    return None
  }
  let mut value = 0
  for k in 0..<count {
    let ch = char_u(text, at + k)
    if !is_digit_u(ch) {
      return None
    }
    value = value * 10 + (ch - '0'.to_uint()).to_int()
  }
  Some(value)
}

///|
/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` -> epoch milliseconds. A trailing `Z` is
/// required: we have no timezone database and inventing an offset for a
/// bare timestamp is exactly the kind of guess a window should refuse.
/// Fractional seconds accept 1..3 digits; more precision than a millisecond
/// is truncated only when the caller wrote it in a form we can round, and
/// we refuse instead of silently dropping digits.
fn iso8601_to_ms(text : String) -> Result[Int64, String] {
  if text.length() < 20 {
    return Err("iso8601 timestamps look like 2024-03-14T16:12:10.493Z")
  }
  let year = match digits_at(text, 0, 4) {
    Some(v) => v
    None => return Err("iso8601 year is not four digits")
  }
  if char_u(text, 4) != '-'.to_uint() || char_u(text, 7) != '-'.to_uint() {
    return Err("iso8601 date is not YYYY-MM-DD")
  }
  let month = match digits_at(text, 5, 2) {
    Some(v) => v
    None => return Err("iso8601 month is not two digits")
  }
  let day = match digits_at(text, 8, 2) {
    Some(v) => v
    None => return Err("iso8601 day is not two digits")
  }
  let sep = char_u(text, 10)
  if sep != 'T'.to_uint() && sep != 't'.to_uint() && sep != ' '.to_uint() {
    return Err("iso8601 date and time must be separated by T")
  }
  if char_u(text, 13) != ':'.to_uint() || char_u(text, 16) != ':'.to_uint() {
    return Err("iso8601 time is not HH:MM:SS")
  }
  let hour = match digits_at(text, 11, 2) {
    Some(v) => v
    None => return Err("iso8601 hour is not two digits")
  }
  let minute = match digits_at(text, 14, 2) {
    Some(v) => v
    None => return Err("iso8601 minute is not two digits")
  }
  let second = match digits_at(text, 17, 2) {
    Some(v) => v
    None => return Err("iso8601 second is not two digits")
  }
  if month < 1 || month > 12 {
    return Err("iso8601 month is out of range")
  }
  if day < 1 || day > days_in_month(year, month) {
    return Err("iso8601 day is out of range for that month")
  }
  if hour > 23 || minute > 59 || second > 59 {
    return Err("iso8601 time is out of range (no leap seconds)")
  }
  // optional fractional seconds, then the mandatory Z
  let mut at = 19
  let mut millis = 0L
  if at < text.length() && char_u(text, at) == '.'.to_uint() {
    at = at + 1
    let mut digits = 0
    while at < text.length() && digits < 3 {
      let ch = char_u(text, at)
      if !is_digit_u(ch) {
        break
      }
      millis = millis * 10L + (ch - '0'.to_uint()).to_int64()
      digits = digits + 1
      at = at + 1
    }
    if digits == 0 {
      return Err("iso8601 fractional seconds have no digits")
    }
    // "1" means 100ms, "12" means 120ms, "123" means 123ms
    while digits < 3 {
      millis = millis * 10L
      digits = digits + 1
    }
    if at < text.length() && is_digit_u(char_u(text, at)) {
      return Err(
        "iso8601 fractional seconds beyond milliseconds are refused, not truncated",
      )
    }
  }
  if at >= text.length() || char_u(text, at) != 'Z'.to_uint() {
    return Err(
      "iso8601 timestamps must end in Z (UTC); we have no timezone data",
    )
  }
  if at + 1 != text.length() {
    return Err("trailing characters after the iso8601 timestamp")
  }
  let days = days_from_civil(year, month, day)
  Ok(
    days * 86400000L +
    hour.to_int64() * 3600000L +
    minute.to_int64() * 60000L +
    second.to_int64() * 1000L +
    millis,
  )
}

///|
/// Reads a numeric JSON field out of a record's value. A missing field or a
/// non-number is a named refusal: silently windowing on the read-time
/// timestamp would produce plausible-looking wrong buckets.
fn field_int64(value : Bytes, field : String) -> Result[Int64, String] {
  if state.time_format == "iso8601" {
    return match @sdk.json_field(value, field) {
      Ok(Some(@sdk.ScalarText(text))) => iso8601_to_ms(text)
      Ok(Some(_)) => Err("field \{field} is not ISO-8601 text")
      Ok(None) => Err("field \{field} is missing from the value")
      Err(e) => Err(e)
    }
  }
  match @sdk.json_field(value, field) {
    Ok(Some(@sdk.ScalarNumber(d))) => {
      let n = d.to_int64()
      if n.to_double() == d {
        Ok(n)
      } else {
        Err("field \{field} is not a whole number of milliseconds")
      }
    }
    Ok(Some(@sdk.ScalarText(_text))) =>
      Err("field \{field} is text, not a number")
    Ok(Some(_)) => Err("field \{field} is not a number")
    Ok(None) => Err("field \{field} is missing from the value")
    Err(e) => Err(e)
  }
}

///|
/// Reads a text field out of a record's value (a key that lives in the
/// payload rather than in the record key).
fn field_text(value : Bytes, field : String) -> Result[String, String] {
  match @sdk.json_field(value, field) {
    Ok(Some(@sdk.ScalarText(text))) => Ok(text)
    Ok(Some(@sdk.ScalarNumber(d))) => Ok(d.to_int64().to_string())
    Ok(Some(@sdk.ScalarBool(b))) => Ok(b.to_string())
    Ok(Some(@sdk.ScalarNull)) => Err("field \{field} is null")
    Ok(None) => Err("field \{field} is missing from the value")
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
      "window_ms" | "time_field" | "key_field" | "time_format" => ()
      _ => return -1
    }
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
  let time_field = match cfg.get("time_field") {
    None => None
    Some(_) => @sdk.config_string(cfg, "time_field")
  }
  match time_field {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.time_field = text
    }
    None => ()
  }
  let time_format = match cfg.get("time_format") {
    None => None
    Some(_) => @sdk.config_string(cfg, "time_format")
  }
  match time_format {
    Some(text) =>
      match text {
        "epoch_ms" | "iso8601" => state.time_format = text
        _ => return -1
      }
    None => ()
  }
  let key_field = match cfg.get("key_field") {
    None => None
    Some(_) => @sdk.config_string(cfg, "key_field")
  }
  match key_field {
    Some(text) => {
      if text.length() == 0 {
        return -1
      }
      state.key_field = text
    }
    None => ()
  }
  0
}

///|
pub fn mf_op_process(input : Bytes) -> Bytes {
  let tumbler = @sdk.GuestOperator::{
    name: "tumble",
    process: fn(records) {
      let out : Array[@protocol.Record] = []
      for r in records {
        let ts = if state.time_field == "" {
          r.timestamp
        } else {
          match field_int64(r.value, state.time_field) {
            Ok(ts) => ts
            Err(e) => return Err(e)
          }
        }
        if ts < 0L {
          return Err("tumble needs non-negative event timestamps (got \{ts})")
        }
        let start = ts / state.window_ms * state.window_ms
        let base = if state.key_field == "" {
          @utf8.decode_lossy(r.key[0:r.key.length()])
        } else {
          match field_text(r.value, state.key_field) {
            Ok(text) => text
            Err(e) => return Err(e)
          }
        }
        // the key stays readable: `word@60000`, not a hash of the pair
        let key = if base.length() == 0 {
          @utf8.encode(start.to_string())
        } else {
          @utf8.encode(base + "@" + start.to_string())
        }
        out.push(@protocol.Record::{
          timestamp: r.timestamp,
          key,
          value: r.value,
          headers: r.headers,
        })
      }
      Ok(out)
    },
  }
  let _ = @sdk.run_buffered(tumbler, input)
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
