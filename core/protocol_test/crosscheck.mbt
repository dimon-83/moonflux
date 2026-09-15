// Blackbox golden-vector crosschecks for core/protocol.
// Imports live in moon.pkg; vectors come from vectors_gen.mbt.

///|
test "golden vectors: encoder reproduces pinned bytes" {
  for c in vector_cases {
    let records = match @protocol.records_from_json(c.records_json) {
      Ok(records) => records
      Err(e) => abort("vector \{c.name}: bad records spec: \{e}")
    }
    let expected = match @codec.hex_decode(c.hex) {
      Ok(data) => data
      Err(e) => abort("vector \{c.name}: bad hex: \{e}")
    }
    let encoded = @protocol.encode_frame(c.base_offset, records)
    assert_true(encoded == expected, msg="vector \{c.name}: encoder drift")
  }
}

///|
test "golden vectors: decoder recovers records from pinned bytes" {
  for c in vector_cases {
    let records = match @protocol.records_from_json(c.records_json) {
      Ok(records) => records
      Err(e) => abort("vector \{c.name}: bad records spec: \{e}")
    }
    let expected = match @codec.hex_decode(c.hex) {
      Ok(data) => data
      Err(e) => abort("vector \{c.name}: bad hex: \{e}")
    }
    match @protocol.decode_frame_strict(expected) {
      Ok(batch) => {
        assert_true(
          batch.base_offset == c.base_offset,
          msg="vector \{c.name}: base offset mismatch",
        )
        assert_true(
          batch.records == records,
          msg="vector \{c.name}: records mismatch",
        )
      }
      Err(e) => abort("vector \{c.name}: decode failed: \{e}")
    }
  }
}
