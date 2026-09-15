// SPDX-License-Identifier: Apache-2.0
// Spec corpus crosschecks. Data comes from
// testdata/spec_corpus.json via corpus_gen.mbt; imports in moon.pkg.

///|
test "valid corpus parses" {
  for c in valid_cases {
    match @spec.parse_spec(c.json) {
      Ok(_) => ()
      Err(errors) => abort("valid case \{c.name} rejected: \{errors}")
    }
  }
}

///|
test "invalid corpus rejected with exactly the pinned codes" {
  for c in invalid_cases {
    match @spec.parse_spec(c.json) {
      Ok(_) => abort("invalid case \{c.name} unexpectedly parsed")
      Err(errors) => {
        assert_eq(
          errors.length(),
          c.expect_codes.length(),
          msg="case \{c.name}: error count",
        )
        for i in 0..<c.expect_codes.length() {
          assert_eq(
            errors[i].code,
            c.expect_codes[i],
            msg="case \{c.name}: code[\{i}]",
          )
        }
      }
    }
  }
}
