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
/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` -> epoch milliseconds. A trailing `Z` is
/// required: we have no timezone database and inventing an offset for a
/// bare timestamp is exactly the kind of guess a window should refuse.
/// Fractional seconds accept 1..3 digits; more precision than a millisecond
/// is truncated only when the caller wrote it in a form we can round, and
/// we refuse instead of silently dropping digits.
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
