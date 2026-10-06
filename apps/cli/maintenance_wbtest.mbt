// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the background-compaction policy (P28): the parse
// rules and the due math are the whole scheduling decision, so they are
// pinned here — the IO around them (enumerate, floor, compact) is the
// same code retention already runs behind gates.

///|
test "maintenance: the cadence knob is also the switch" {
  // absent = off: rewriting data is never a default
  assert_eq(parse_compact_interval_ms(None), 0L)
  // a positive interval enables the pass
  assert_eq(parse_compact_interval_ms(Some("400")), 400L)
  // 0 must mean "never", not "fire every tick"
  assert_eq(parse_compact_interval_ms(Some("0")), 0L)
  assert_eq(parse_compact_interval_ms(Some("-5")), 0L)
  // junk is off, not a crash
  assert_eq(parse_compact_interval_ms(Some("soon")), 0L)
}

///|
test "maintenance: the rewrite lever defaults to zero" {
  // absent = rewrite as soon as anything is droppable: the manual
  // command's semantics, unchanged
  assert_eq(parse_min_dirty_bytes(None), 0)
  assert_eq(parse_min_dirty_bytes(Some("1024")), 1024)
  // a negative or junk threshold is not a refusal — it is 0
  assert_eq(parse_min_dirty_bytes(Some("-1")), 0)
  assert_eq(parse_min_dirty_bytes(Some("plenty")), 0)
}

///|
test "maintenance: due math" {
  // a pass that never ran is due as soon as the feature is on
  assert_true(maintenance_due(-1L, 10_000L, 400L))
  // inside the interval: not due
  assert_false(maintenance_due(10_000L, 10_100L, 400L))
  assert_false(maintenance_due(10_000L, 10_399L, 400L))
  // the interval covered: due
  assert_true(maintenance_due(10_000L, 10_400L, 400L))
  // interval 0 (the switch) never fires, even for a first pass
  assert_false(maintenance_due(-1L, 10_000L, 0L))
}
