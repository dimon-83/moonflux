// SPDX-License-Identifier: Apache-2.0
// White-box tests for the fetch reply's offset framing (P18/T76):
// one frame per contiguous run of origin offsets, so a hole (a filter
// rule, or compaction before the fetch ever ran) or a fan-out
// duplicate starts a new frame whose base is the record's true offset
// — and the client's base+index derivation stays truthful.

///|
fn packer_record(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 0L,
    key: b"",
    value: @utf8.encode(value[0:value.length()]),
    headers: [],
  }
}

///|
fn decoded_base(frame : Bytes) -> Int64 {
  match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.base_offset
    Err(e) => abort("decode: \{e}")
  }
}

///|
fn decoded_len(frame : Bytes) -> Int {
  match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records.length()
    Err(e) => abort("decode: \{e}")
  }
}

///|
test "a contiguous window packs into one frame" {
  let packer = ReplyPacker::new(0L)
  packer.add(0L, packer_record("a"))
  packer.add(1L, packer_record("b"))
  packer.add(2L, packer_record("c"))
  let frames = packer.finish()
  assert_eq(frames.length(), 1)
  assert_eq(decoded_base(frames[0]), 0L)
  assert_eq(decoded_len(frames[0]), 3)
}

///|
test "a hole starts a new frame at the survivor's true offset" {
  // the measured case: survivors 0, 2, 3 after compaction dropped 1 —
  // a single frame based at 0 came back printed as 0, 1, 2
  let packer = ReplyPacker::new(0L)
  packer.add(0L, packer_record("a"))
  packer.add(2L, packer_record("c"))
  packer.add(3L, packer_record("d"))
  let frames = packer.finish()
  assert_eq(frames.length(), 2)
  assert_eq(decoded_base(frames[0]), 0L)
  assert_eq(decoded_len(frames[0]), 1)
  assert_eq(decoded_base(frames[1]), 2L)
  assert_eq(decoded_len(frames[1]), 2)
}

///|
test "a fan-out duplicate gets its own frame with the same base" {
  // a rule that emits two records from one input: both name the same
  // origin, and packing them together would invent an offset for the
  // second that belongs to some other record
  let packer = ReplyPacker::new(5L)
  packer.add(5L, packer_record("first"))
  packer.add(5L, packer_record("second"))
  let frames = packer.finish()
  assert_eq(frames.length(), 2)
  assert_eq(decoded_base(frames[0]), 5L)
  assert_eq(decoded_base(frames[1]), 5L)
  assert_eq(decoded_len(frames[0]), 1)
  assert_eq(decoded_len(frames[1]), 1)
}

///|
test "runs resume after a hole" {
  let packer = ReplyPacker::new(0L)
  packer.add(0L, packer_record("a"))
  packer.add(1L, packer_record("b"))
  packer.add(3L, packer_record("d"))
  packer.add(4L, packer_record("e"))
  let frames = packer.finish()
  assert_eq(frames.length(), 2)
  assert_eq(decoded_base(frames[0]), 0L)
  assert_eq(decoded_len(frames[0]), 2)
  assert_eq(decoded_base(frames[1]), 3L)
  assert_eq(decoded_len(frames[1]), 2)
}

///|
test "an empty window packs into no frames" {
  let packer = ReplyPacker::new(7L)
  assert_eq(packer.finish().length(), 0)
  // and the window's base stays where the caller asked
  assert_eq(packer.first, 7L)
}

///|
test "the packer reports the first contributing offset" {
  let packer = ReplyPacker::new(9L)
  packer.add(9L, packer_record("a"))
  packer.add(11L, packer_record("c"))
  let _ = packer.finish()
  assert_eq(packer.first, 9L)
}
