// SPDX-License-Identifier: Apache-2.0
// White-box tests for flag parsing (P18/T76): a boolean flag must never
// eat the argument after it — `--committed --remote X` used to parse
// `--remote` as committed's value and silently run a *local* consume
// against the default data dir.

///|
test "a boolean flag never eats the argument after it" {
  let flags = parse_flags([
    "--committed", "--remote", "127.0.0.1:19000", "--topic", "t",
  ])
  assert_true(flags.get("committed") is Some(_))
  assert_eq(flags.get("remote"), Some("127.0.0.1:19000"))
  assert_eq(flags.get("topic"), Some("t"))
}

///|
test "boolean flags keep their last-position and = forms" {
  let trailing = parse_flags(["--topic", "t", "--remote", "h:1", "--verify"])
  assert_true(trailing.get("verify") is Some(_))
  assert_eq(trailing.get("remote"), Some("h:1"))
  let assigned = parse_flags(["--verify=true", "--topic", "t"])
  assert_true(assigned.get("verify") is Some(_))
  assert_eq(assigned.get("topic"), Some("t"))
}

///|
test "value flags still take the next argument" {
  let flags = parse_flags(["--topic", "t", "--from", "7"])
  assert_eq(flags.get("topic"), Some("t"))
  assert_eq(flags.get("from"), Some("7"))
}

///|
test "a lone boolean at the end of the line still parses" {
  let flags = parse_flags(["--topic", "t", "--follow"])
  assert_true(flags.get("follow") is Some(_))
  assert_eq(flags.get("topic"), Some("t"))
}
