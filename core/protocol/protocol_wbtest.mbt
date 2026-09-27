// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for core/protocol — round trips, corruption
// injection, and bound enforcement (AGENTS §5).

///|
fn rec(timestamp : Int64, key : Bytes, value : Bytes) -> Record {
  Record::{ timestamp, key, value, headers: [], }
}

///|
test "frame round trip empty batch" {
  let frame = encode_frame(0L, [])
  let decoded = decode_frame_strict(frame)
  assert_eq(decoded, Ok(DecodedBatch::{ base_offset: 0L, records: [], }))
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
    Ok(DecodedBatch::{ base_offset: 42L, records, }),
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
    Ok(DecodedBatch::{ base_offset: 7L, records, }),
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
    Ok(DecodedBatch::{ base_offset: 0L, records: [rec(1L, b"", b"a")], }),
  )
  assert_eq(
    decode_frame(reader),
    Ok(DecodedBatch::{ base_offset: 0L, records: [rec(2L, b"", b"b")], }),
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
    Ok(DecodedBatch::{ base_offset: -1L, records: [rec(0L, b"", b"x")], }),
  )
}

///|
test "the size accounting matches the encoder byte for byte" {
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
  // the whole point of the accounting is that it is not an estimate:
  // a producer budgets against it and the frame it then encodes must
  // land exactly where the budget said it would (P15)
  assert_eq(batch_wire_size(records), encode_frame(0L, records).length())
  let mut sum = 0
  for record in records {
    sum += record_wire_size(record)
  }
  assert_eq(sum + 28, batch_wire_size(records))
  // a varint length prefix grows at 128, so the accounting has to as
  // well: a 200-byte value costs more than 202 bytes on the wire
  let filler = Buffer::Buffer()
  for _ in 0..<200 {
    filler.write_byte(b'z')
  }
  let big = [rec(0L, b"", filler.to_bytes())]
  assert_eq(batch_wire_size(big), encode_frame(0L, big).length())
  assert_true(batch_wire_size(big) > 28 + 8 + 2 + 200)
}

///|
test "batch_fit fills a budget exactly and never returns zero for a non-empty input" {
  let one = [rec(0L, b"", b"0123456789")]
  let unit = batch_wire_size(one)
  assert_eq(batch_fit(one, unit), 1)
  assert_eq(batch_fit(one, unit - 1), 1) // at least one, always
  assert_eq(batch_fit(one, 0), 1) // no budget = everything fits
  let three = [
    rec(0L, b"", b"0123456789"),
    rec(0L, b"", b"0123456789"),
    rec(0L, b"", b"0123456789"),
  ]
  assert_eq(batch_fit(three, 0), 3)
  // the budget is a *frame* size, and the frame header is only paid
  // once per batch: a budget of exactly two records' frame takes two
  // records (a budget is not "n x one-record frame")
  assert_eq(batch_fit(three, batch_wire_size(three[0:2].to_owned())), 2)
  assert_eq(batch_fit(three, batch_wire_size(three)), 3)
  assert_eq(batch_fit(three, batch_wire_size(three) - 1), 2)
  assert_eq(batch_fit([], 100), 0)
}

///|
test "split_batches preserves order, respects the budget, and reports one range" {
  let records : Array[Record] = []
  for i in 0..<10 {
    records.push(rec(i.to_int64(), b"", b"0123456789"))
  }
  let four = batch_wire_size(records[0:4].to_owned())
  let batches = split_batches(records, four)
  assert_eq(batches.length(), 3)
  assert_eq(batches[0].length(), 4)
  assert_eq(batches[1].length(), 4)
  assert_eq(batches[2].length(), 2)
  // concatenation is the input, in order: consecutive batches are
  // consecutive offsets, which is what lets a producer report one
  // range and a consumer derive offsets from a base (P15)
  let rebuilt : Array[Record] = []
  for batch in batches {
    assert_true(batch_wire_size(batch) <= four)
    for record in batch {
      rebuilt.push(record)
    }
  }
  assert_eq(rebuilt, records)
  // one record larger than the budget is still its own batch: the
  // decoder refuses it with a reason, which beats a silent stall
  let huge = [rec(0L, b"", b"0123456789")]
  let solo = split_batches(huge, 4)
  assert_eq(solo.length(), 1)
  assert_eq(solo[0].length(), 1)
  // an empty send is one empty batch, so the caller still gets an answer
  assert_eq(split_batches([], 1024).length(), 1)
  assert_eq(split_batches([], 1024)[0].length(), 0)
}

///|
test "a record over the per-field limit is named before it reaches the wire" {
  let big = Buffer::Buffer()
  for _ in 0..<MAX_RECORD_BYTES {
    big.write_byte(b'z')
  }
  let at_limit = rec(0L, b"", big.to_bytes())
  assert_eq(record_size_violation(at_limit), None)
  big.write_byte(b'z')
  let over = rec(0L, b"", big.to_bytes())
  match record_size_violation(over) {
    Some(reason) => assert_true(reason.contains("per-field limit"))
    None => abort("an oversize value was not reported")
  }
  let bad_key = Record::{
    timestamp: 0L,
    key: big.to_bytes(),
    value: b"",
    headers: [],
  }
  match record_size_violation(bad_key) {
    Some(reason) => assert_true(reason.contains("key"))
    None => abort("an oversize key was not reported")
  }
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
