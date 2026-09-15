// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/protocol — round trips, corruption
// injection, and bound enforcement (AGENTS §5).

///|
fn rec(timestamp : Int64, key : Bytes, value : Bytes) -> Record {
  Record::{ timestamp, key, value, headers: [] }
}

///|
test "frame round trip empty batch" {
  let frame = encode_frame(0L, [])
  let decoded = decode_frame_strict(frame)
  assert_eq(decoded, Ok(DecodedBatch::{ base_offset: 0L, records: [] }))
}

///|
test "frame round trip multi record with headers" {
  let records = [
    rec(1726000000000L, b"", b"hello"),
    rec(1L, b"k", b"v"),
    Record::{
      timestamp: -1L,
      key: b"\x00\xff",
      value: b"\x00\x00",
      headers: [(b"h1", b"v1"), (b"", b"")],
    },
  ]
  let frame = encode_frame(42L, records)
  assert_eq(
    decode_frame_strict(frame),
    Ok(DecodedBatch::{ base_offset: 42L, records }),
  )
}

///|
test "decode is deterministic and encode is injective here" {
  let records = [rec(5L, b"key", b"value")]
  assert_eq(encode_frame(0L, records), encode_frame(0L, records))
  // base_offset is outside the CRC but present in the frame: changing
  // it changes bytes and decodes back with the new offset
  assert_eq(
    decode_frame_strict(encode_frame(7L, records)),
    Ok(DecodedBatch::{ base_offset: 7L, records }),
  )
}

///|
test "bad magic rejected" {
  let frame = encode_frame(0L, [rec(0L, b"", b"x")])
  let corrupted = flip_byte(frame, 1, b'X')
  assert_eq(decode_frame_strict(corrupted), Err(BadMagic))
}

///|
test "unsupported version rejected" {
  let frame = encode_frame(0L, [rec(0L, b"", b"x")])
  let corrupted = flip_byte(frame, 3, b'\x02')
  assert_eq(decode_frame_strict(corrupted), Err(UnsupportedVersion(2)))
}

///|
test "crc mismatch detected" {
  let frame = encode_frame(0L, [rec(0L, b"", b"payload")])
  // byte 28 is inside the records blob
  let corrupted = flip_byte(frame, 28, b'!')
  assert_eq(decode_frame_strict(corrupted), Err(CrcMismatch))
}

///|
test "truncation reported as incomplete" {
  let frame = encode_frame(0L, [rec(0L, b"", b"payload"), rec(9L, b"k", b"v")])
  // cut at every prefix shorter than the frame: none may decode
  let total = frame.length()
  for cut in 0..<total {
    let part = frame[0:cut].to_owned()
    match decode_frame_strict(part) {
      Err(Incomplete) => ()
      Err(BadMagic) => () // 0-byte or short-magic prefixes
      other => abort("cut \{cut} decoded as \{other}")
    }
  }
}

///|
test "trailing bytes rejected in strict decode but framed decode consumes one" {
  let one = encode_frame(0L, [rec(1L, b"", b"a")])
  let two = encode_frame(0L, [rec(2L, b"", b"b")])
  let joined = Buffer::Buffer()
  joined.write_bytes(one[0:one.length()])
  joined.write_bytes(two[0:two.length()])
  let bytes = joined.to_bytes()
  assert_eq(decode_frame_strict(bytes), Err(MalformedLength))
  let reader = @codec.Reader::new(bytes)
  assert_eq(
    decode_frame(reader),
    Ok(DecodedBatch::{ base_offset: 0L, records: [rec(1L, b"", b"a")] }),
  )
  assert_eq(
    decode_frame(reader),
    Ok(DecodedBatch::{ base_offset: 0L, records: [rec(2L, b"", b"b")] }),
  )
  assert_true(reader.is_empty())
}

///|
test "length field beyond limits rejected without allocation" {
  // hand-craft: valid magic/version, batch_length = MAX_BATCH_BYTES+1
  let buf = Buffer::Buffer()
  buf.write_bytes(b"MFB"[0:3])
  buf.write_byte(b'\x01')
  buf.write_uint_be((MAX_BATCH_BYTES + 1).reinterpret_as_uint())
  buf.write_int64_be(0L)
  buf.write_uint_be(0U)
  buf.write_uint_be(0U)
  buf.write_uint_be(0U)
  assert_eq(decode_frame_strict(buf.to_bytes()), Err(ValueTooLarge))
}

///|
test "base_offset of -1 allowed for unassigned producer frames" {
  let frame = encode_frame(-1L, [rec(0L, b"", b"x")])
  assert_eq(
    decode_frame_strict(frame),
    Ok(DecodedBatch::{ base_offset: -1L, records: [rec(0L, b"", b"x")] }),
  )
}

///|
fn flip_byte(data : Bytes, index : Int, replacement : Byte) -> Bytes {
  let out = Buffer::Buffer()
  for i in 0..<data.length() {
    if i == index {
      out.write_byte(replacement)
    } else {
      out.write_byte(data[i])
    }
  }
  out.to_bytes()
}
