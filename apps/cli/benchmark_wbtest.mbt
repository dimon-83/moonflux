// SPDX-License-Identifier: Apache-2.0
// White-box tests for the benchmark's pure pieces (P17): the
// nearest-rank percentiles, the histogram line, and the offset-header
// record shaping that `--verify` depends on.

///|
test "percentile_rank is nearest-rank with clamped ends" {
  assert_eq(percentile_rank(100, 50), 50)
  assert_eq(percentile_rank(100, 0), 1)
  assert_eq(percentile_rank(100, 100), 100)
  // 98 samples: ceil(0.5 * 98) = 49, not 50 — the rank is a count, not
  // an interpolation
  assert_eq(percentile_rank(98, 50), 49)
  assert_eq(percentile_rank(1, 99), 1)
  // an empty sample set is the caller's bug; the rank clamps rather
  // than crashes, and callers that can see zero samples guard first
  assert_eq(percentile_rank(0, 50), 1)
}

///|
test "percentile_us walks a sorted array" {
  let sorted = [10L, 20L, 30L, 40L, 50L]
  assert_eq(percentile_us(sorted, 0), 10L)
  assert_eq(percentile_us(sorted, 50), 30L)
  assert_eq(percentile_us(sorted, 100), 50L)
}

///|
test "stats_line sorts, averages, and reports the count" {
  let line = stats_line("x_us", [9L, 1L, 5L, 3L, 7L])
  assert_true(line.contains("x_us min=1"))
  assert_true(line.contains("avg=5"))
  assert_true(line.contains("p50=5"))
  assert_true(line.contains("max=9"))
  assert_true(line.contains("count=5"))
  assert_eq(stats_line("empty_us", []), "empty_us count=0")
}

///|
test "the benchmark value header names its own offset" {
  let fill = bench_fill_bytes(60)
  let value = bench_value(1234567L, 64, fill)
  assert_eq(value.length(), 64)
  // 1234567 = 0x0012D687, big-endian: pin the write byte by byte so a
  // failure here names the side (write vs read) that broke
  assert_eq(value[0], 0)
  assert_eq(value[1], 0x12)
  assert_eq(value[2], 0xD6)
  assert_eq(value[3], 0x87)
  assert_eq(bench_value_offset(value), 1234567L)
  // the fill is dots, so a value that leaks into human output is
  // recognisably a benchmark record
  assert_eq(value[4], 0x2E)
  assert_eq(value[63], 0x2E)
  // the header survives the boundaries: offset 0 and a large offset
  assert_eq(bench_value_offset(bench_value(0L, 8, bench_fill_bytes(4))), 0L)
  assert_eq(
    bench_value_offset(bench_value(2147483647L, 8, bench_fill_bytes(4))),
    2147483647L,
  )
}

///|
test "bench_entry_ok trusts only values that carry a header" {
  fn entry_at(offset : Int64, value : Bytes) -> @log.LogEntry {
    @log.LogEntry::{
      offset,
      record: @protocol.Record::{ timestamp: 0L, key: b"", value, headers: [], },
    }
  }
  // header matches the offset: intact
  assert_true(
    bench_entry_ok(entry_at(7L, bench_value(7L, 64, bench_fill_bytes(60)))),
  )
  // header names another offset: broken — this is the tripwire
  assert_true(
    !bench_entry_ok(entry_at(8L, bench_value(7L, 64, bench_fill_bytes(60)))),
  )
  // too short to carry a header: not a benchmark record, not our claim
  assert_true(bench_entry_ok(entry_at(7L, b"hi")))
}
