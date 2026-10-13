// SPDX-License-Identifier: Apache-2.0
// Shared guest helpers: parsing an ISO-8601 timestamp into epoch milliseconds.
//
// This lives in the SDK because more than one operator needs it (the window
// keyer and the windowed top-N flush), and a date parser copied into two
// guests is two chances to disagree about leap years. It is pure computation
// — parsing a date is not reading a clock — so it stays inside the kernel's
// red line. A trailing `Z` is required: we have no timezone database, and
// inventing an offset for a naive timestamp is exactly the guess a window
// should refuse.

///|
/// Days between 1970-01-01 and `y-m-d` (Howard Hinnant's civil-days
/// algorithm). Pure integer arithmetic: parsing a date is computation, not
/// a clock read, so this stays inside the kernel's red line.
fn days_from_civil(y : Int32, m : Int32, d : Int32) -> Int64 {
  let y2 = if m <= 2 { y - 1 } else { y }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe - 719468).to_int64()
}

///|
fn days_in_month(y : Int32, m : Int32) -> Int32 {
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
fn char_u(text : String, at : Int32) -> UInt32 {
  text.unsafe_charcode_at(at).to_uint()
}

///|
fn is_digit_u(c : UInt32) -> Bool {
  c >= '0'.to_uint() && c <= '9'.to_uint()
}

///|
fn digits_at(text : String, at : Int32, count : Int32) -> Int32? {
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
/// `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)` -> epoch milliseconds. An offset is
/// required: we have no timezone database and inventing an offset for a
/// bare timestamp is exactly the kind of guess a window should refuse.
/// Fractional seconds accept any number of digits; beyond milliseconds the
/// extra digits are validated and then truncated (a real feed's microseconds
/// must not make its timestamps unreadable — see the note at the truncation).
pub fn parse_iso8601_ms(text : String) -> Result[Int64, String] {
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
    // Beyond milliseconds we TRUNCATE — after checking that the rest really are
    // digits. This reverses an earlier "refuse, not truncate" rule on purpose:
    // a real plant feed (PostgREST on ia_csc.inlet_node_value) emits
    // `...04:16:00.520788+08:00`, so refusing made the platform unable to read
    // the feed at all, while its time resolution is milliseconds and every
    // consumer measures DURATIONS, where dropping sub-millisecond digits cannot
    // change an answer. Non-digit junk is still refused, so a malformed
    // timestamp cannot sneak in through this door.
    while at < text.length() && is_digit_u(char_u(text, at)) {
      at = at + 1
    }
  }
  // A FIXED offset (`Z`, `+08:00`, `-0530`) is pure arithmetic and needs no
  // timezone database, so it is accepted. A bare local timestamp is still
  // refused, and so is a named zone — those DO need data we do not carry.
  // (Measured: a real PostgREST feed emits `2026-10-14T04:16:00.520788+08:00`,
  // so refusing offsets made the feed unreadable.)
  let mut offset_ms = 0L
  if at < text.length() && char_u(text, at) == 'Z'.to_uint() {
    at = at + 1
  } else if at < text.length() &&
    (char_u(text, at) == '+'.to_uint() || char_u(text, at) == '-'.to_uint()) {
    let sign = if char_u(text, at) == '-'.to_uint() { -1L } else { 1L }
    at = at + 1
    let off_hour = match digits_at(text, at, 2) {
      Some(v) => v
      None => return Err("iso8601 offset needs two hour digits")
    }
    at = at + 2
    let mut off_min = 0
    if at < text.length() && char_u(text, at) == ':'.to_uint() {
      at = at + 1
    }
    if at < text.length() && is_digit_u(char_u(text, at)) {
      off_min = match digits_at(text, at, 2) {
        Some(v) => v
        None => return Err("iso8601 offset needs two minute digits")
      }
      at = at + 2
    }
    if off_hour > 23 || off_min > 59 {
      return Err("iso8601 offset is out of range")
    }
    offset_ms = sign *
      (off_hour.to_int64() * 3600000L + off_min.to_int64() * 60000L)
  } else {
    return Err("iso8601 timestamps need Z or a fixed +HH:MM offset")
  }
  if at != text.length() {
    return Err("trailing characters after the iso8601 timestamp")
  }
  let days = days_from_civil(year, month, day)
  Ok(
    days * 86400000L +
    hour.to_int64() * 3600000L +
    minute.to_int64() * 60000L +
    second.to_int64() * 1000L +
    millis -
    offset_ms,
  )
}
