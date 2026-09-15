// vectortool: emits the golden-vector JSON for the wire protocol.
// The printed document is reviewed once and checked in as
// core/protocol/testdata/protocol_vectors.json — the source of truth
// for byte-level crosschecks (AGENTS §5: vectors live in data files).
//
// Each case pins (name, base_offset, records spec, encoded bytes).
// The bytes are produced by the current encoder, so regeneration
// after an intentional format change produces a reviewable diff.

///|
fn emit_case(
  name : String,
  base_offset : Int64,
  records_json : String,
) -> String {
  let records = match @protocol.records_from_json(records_json) {
    Ok(records) => records
    Err(e) => abort("case \{name}: bad records json: \{e}")
  }
  let hex = @codec.hex_encode(@protocol.encode_frame(base_offset, records))
  "{ \"name\": \"\{name}\", \"base_offset\": \{base_offset}, \"records\": \{records_json}, \"hex\": \"\{hex}\" }"
}

///|
/// A value of 300 identical bytes exercises multi-byte ULEB128
/// lengths without hand-writing the hex.
fn case_wide_varint() -> String {
  let sb = StringBuilder::new()
  sb.write_string("[{ \"timestamp\": 7, \"key\": \"\", \"value\": \"")
  for _i in 0..<300 {
    sb.write_string("ab")
  }
  sb.write_string("\", \"headers\": [] }]")
  emit_case("two-byte-varint-length", 0L, sb.to_string())
}

///|
fn case_many_headers() -> String {
  let sb = StringBuilder::new()
  sb.write_string(
    "[{ \"timestamp\": 2, \"key\": \"6b\", \"value\": \"76\", \"headers\": [",
  )
  for i in 0..<8 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(
      "[\"68\{(@codec.hex_encode(Bytes::from_array([i.to_byte()]))[0:2])}\", \"\"]",
    )
  }
  sb.write_string("] }]")
  emit_case("multiple-headers", 3L, sb.to_string())
}

///|
fn main {
  let cases = [
    emit_case("empty-batch", 0L, "[]"),
    emit_case(
      "single-empty-record", 0L, "[{ \"timestamp\": 0, \"key\": \"\", \"value\": \"\", \"headers\": [] }]",
    ),
    emit_case(
      "single-record", 0L, "[{ \"timestamp\": 1726000000000, \"key\": \"\", \"value\": \"68656c6c6f\", \"headers\": [] }]",
    ),
    emit_case(
      "key-and-value", 1L, "[{ \"timestamp\": 1726000000001, \"key\": \"6b31\", \"value\": \"7631\", \"headers\": [] }]",
    ),
    emit_case(
      "binary-payload", 0L, "[{ \"timestamp\": 1, \"key\": \"00ff10\", \"value\": \"00ff80fefeff\", \"headers\": [] }]",
    ),
    emit_case(
      "multi-record", 9L, "[{ \"timestamp\": 1726000000010, \"key\": \"\", \"value\": \"61\", \"headers\": [] }, { \"timestamp\": 1726000000011, \"key\": \"6b32\", \"value\": \"6262\", \"headers\": [] }, { \"timestamp\": 1726000000012, \"key\": \"\", \"value\": \"\", \"headers\": [] }]",
    ),
    emit_case(
      "with-headers", 2L, "[{ \"timestamp\": 1726000000002, \"key\": \"\", \"value\": \"78797a\", \"headers\": [[\"6831\", \"7631\"], [\"\", \"\"], [\"7a\", \"313233\"]] }]",
    ),
    case_wide_varint(),
    case_many_headers(),
    emit_case(
      "negative-timestamp", 0L, "[{ \"timestamp\": -1, \"key\": \"\", \"value\": \"6e6567\", \"headers\": [] }]",
    ),
    emit_case(
      "unassigned-offset", -1L, "[{ \"timestamp\": 5, \"key\": \"\", \"value\": \"70696e67\", \"headers\": [] }]",
    ),
  ]
  let out = StringBuilder::new()
  out.write_string("[\n")
  for i, c in cases {
    out.write_string(c)
    if i + 1 < cases.length() {
      out.write_string(",")
    }
    out.write_string("\n")
  }
  out.write_string("]\n")
  println(out.to_string())
}
