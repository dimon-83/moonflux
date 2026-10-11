// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the tumble operator's date arithmetic: the window must
// be computed from the data, never from a clock (kernel red line), so the
// converter has to be right on its own.

///|
test "iso8601 timestamps convert to epoch milliseconds" {
  assert_eq(parse_iso8601_ms("1970-01-01T00:00:00.000Z"), Ok(0L))
  assert_eq(parse_iso8601_ms("1970-01-01T00:00:00Z"), Ok(0L))
  assert_eq(parse_iso8601_ms("2024-03-14T16:12:10.493Z"), Ok(1710432730493L))
  // leap day, and the century rule
  assert_eq(parse_iso8601_ms("2024-02-29T00:00:00Z"), Ok(1709164800000L))
  assert_eq(parse_iso8601_ms("2000-01-01T00:00:00Z"), Ok(946684800000L))
  // before the epoch is a negative time, not an error
  assert_eq(parse_iso8601_ms("1969-12-31T23:59:59Z"), Ok(-1000L))
  // fractional digits mean tenths/hundredths, not raw milliseconds
  assert_eq(parse_iso8601_ms("1970-01-01T00:00:00.1Z"), Ok(100L))
  assert_eq(parse_iso8601_ms("1970-01-01T00:00:00.12Z"), Ok(120L))
}

///|
test "iso8601 refuses what it cannot represent, by name" {
  // 2023 is not a leap year
  assert_true(parse_iso8601_ms("2023-02-29T00:00:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-13-01T00:00:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-00-01T00:00:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-04-31T00:00:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14T24:00:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14T16:60:00Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14T16:12:60Z") is Err(_))
  // no timezone database: a bare local timestamp is refused, not guessed
  assert_true(parse_iso8601_ms("2024-03-14T16:12:10") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14T16:12:10+02:00") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14 16:12:10Z") is Ok(1710432730000L))
  // sub-millisecond precision is refused rather than truncated
  assert_true(parse_iso8601_ms("2024-03-14T16:12:10.4931Z") is Err(_))
  assert_true(parse_iso8601_ms("2024-03-14T16:12:10.Z") is Err(_))
  assert_true(parse_iso8601_ms("not a timestamp") is Err(_))
  assert_true(parse_iso8601_ms("") is Err(_))
}
