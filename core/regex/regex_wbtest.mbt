// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/regex: the supported subset, the refusals, and
// the simulation's behaviour on inputs that break backtrackers.

///|
/// Compile-or-abort, for the cases that must be supported.
fn re(pattern : String) -> Regex {
  match compile(pattern) {
    Ok(re) => re
    Err(e) => abort("compile(\{pattern}): \{e}")
  }
}

///|
/// The refusal text, for the cases that must not be supported.
fn refusal(pattern : String) -> String {
  match compile(pattern) {
    Ok(_) => abort("compile(\{pattern}) should have been refused")
    Err(e) => e
  }
}

///|
test "literals, dot and quantifiers" {
  assert_true(is_match(re("abc"), "xxabcxx"))
  assert_false(is_match(re("abc"), "abx"))
  assert_true(is_match(re("a.c"), "abc"))
  assert_false(is_match(re("a.c"), "a\nc"))
  assert_true(is_match(re("ab*c"), "ac"))
  assert_true(is_match(re("ab*c"), "abbbc"))
  assert_false(is_match(re("ab+c"), "ac"))
  assert_true(is_match(re("ab+c"), "abc"))
  assert_true(is_match(re("ab?c"), "ac"))
  assert_true(is_match(re("ab?c"), "abc"))
  assert_false(is_match(re("ab?c"), "abbc"))
}

///|
test "bounded repetition" {
  assert_false(is_match(re("a{3}"), "aa"))
  assert_true(is_match(re("a{3}"), "aaa"))
  assert_true(is_match(re("a{3}"), "aaaa"))
  assert_true(is_match(re("a{2,3}"), "aa"))
  assert_true(is_match(re("a{2,3}"), "aaa"))
  assert_true(is_match(re("^a{2,3}$"), "aaa"))
  assert_false(is_match(re("^a{2,3}$"), "aaaa"))
  assert_true(is_match(re("^a{2,}$"), "aaaaa"))
  assert_false(is_match(re("^a{2,}$"), "a"))
  // the count is bounded, so a hostile pattern is refused rather than
  // expanded into a million instructions
  assert_true(refusal("a{99999}").contains("too large"))
}

///|
test "character classes" {
  assert_true(is_match(re("[abc]"), "xby"))
  assert_false(is_match(re("^[abc]$"), "d"))
  assert_true(is_match(re("^[^abc]$"), "d"))
  assert_false(is_match(re("^[^abc]$"), "a"))
  assert_true(is_match(re("^[a-z0-9]$"), "q"))
  assert_true(is_match(re("^[a-z0-9]$"), "7"))
  assert_false(is_match(re("^[a-z0-9]$"), "Q"))
  // a `]` first up is a literal, and so is a trailing `-`
  assert_true(is_match(re("^[]]$"), "]"))
  assert_true(is_match(re("^[a-]$"), "-"))
  assert_true(is_match(re("^[-a]$"), "-"))
  assert_true(is_match(re("^[\\d]$"), "5"))
  assert_true(is_match(re("^[\\w]$"), "_"))
  assert_false(is_match(re("^[\\w]$"), "-"))
  assert_true(is_match(re("^[\\s]$"), " "))
  assert_true(is_match(re("^[\\s]$"), "\t"))
}

///|
test "anchors are string anchors, not line anchors" {
  assert_true(is_match(re("^abc"), "abc"))
  assert_false(is_match(re("^abc"), "xabc"))
  assert_true(is_match(re("abc$"), "xabc"))
  assert_false(is_match(re("abc$"), "abcx"))
  assert_true(is_match(re("^abc$"), "abc"))
  assert_false(is_match(re("^abc$"), "abcd"))
  // byte semantics: the pattern sees the newline as an ordinary byte, so
  // an "end of line" match in the middle of a string does not happen
  assert_false(is_match(re("^abc$"), "abc\ndef"))
}

///|
test "groups and alternation" {
  assert_true(is_match(re("(ab|cd)+"), "abcdab"))
  assert_false(is_match(re("^(ab|cd)+$"), "abce"))
  assert_true(is_match(re("a|bc"), "xxbcxx"))
  assert_true(is_match(re("x(a|b)y"), "xby"))
  assert_false(is_match(re("^(a|b)c$"), "acd"))
  assert_true(is_match(re("^(a|b)c$"), "bc"))
  // empty alternatives are just matches
  assert_true(is_match(re("(a|)b"), "b"))
  assert_true(is_match(re(""), "anything"))
  assert_true(is_match(re(""), ""))
}

///|
test "the SDF regex example's pattern classifies birth years" {
  let r = re("(199[7-9])|(200[0-9])|(201[0-2])")
  assert_true(is_match(r, "{\"name\": \"Alice\", \"born\": 1998}"))
  assert_true(is_match(r, "{\"name\": \"Bob\", \"born\": 2011}"))
  assert_false(is_match(r, "{\"name\": \"John\", \"born\": 1996}"))
  assert_false(is_match(r, "{\"name\": \"Michael\", \"born\": 2018}"))
  assert_true(is_match(r, "2012"))
  assert_false(is_match(r, "2013"))
}

///|
test "linear simulation: patterns that break backtrackers stay cheap" {
  // under backtracking, (a*)*b on a long run of a's is the classic
  // exponential case; the state-set simulation visits each position once
  let text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  assert_false(is_match(re("^(a*)*b$"), text))
  assert_true(is_match(re("^(a*)*b$"), text + "b"))
  assert_false(is_match(re("^(a|aa)+$"), text + "c"))
  assert_true(is_match(re("^(a|aa)+$"), text))
}

///|
test "unsupported constructs are refused by name, never approximated" {
  assert_true(refusal("\\bword\\b").contains("word boundary"))
  assert_true(refusal("a\\Bb").contains("word boundary"))
  assert_true(refusal("(a)\\1").contains("backreference"))
  assert_true(refusal("a(?=b)").contains("lookaround"))
  assert_true(refusal("a(?!b)").contains("lookaround"))
  assert_true(refusal("(?<=a)b").contains("lookaround"))
  assert_true(refusal("(?P<n>a)").contains("named group"))
  assert_true(refusal("(?i)abc").contains("group flags"))
  assert_true(refusal("a*?").contains("lazy"))
  assert_true(refusal("a+?").contains("lazy"))
  assert_true(refusal("a??").contains("lazy"))
  assert_true(refusal("a*+").contains("lazy"))
  assert_true(refusal("\\p{L}").contains("Unicode"))
  assert_true(refusal("[\\D]").contains("negated shorthand"))
  assert_true(refusal("[a-\\d]").contains("single-character endpoints"))
}

///|
test "malformed patterns explain themselves" {
  assert_true(refusal("[abc").contains("unclosed character class"))
  assert_true(refusal("(abc").contains("unclosed group"))
  assert_true(refusal("abc)").contains("unmatched )"))
  assert_true(refusal("*abc").contains("nothing to repeat"))
  assert_true(refusal("a{").contains("repetition"))
  assert_true(refusal("a{3,2}").contains("max < min"))
  assert_true(refusal("a\\").contains("dangling backslash"))
  assert_true(refusal("a\\q").contains("unknown escape"))
  assert_true(refusal("a{z}").contains("repetition"))
  assert_true(refusal("[z-a]").contains("invalid character range"))
}
