// Whitebox tests for core/codec — observe internal edge behavior that
// the public contract does not pin down (AGENTS §4).

///|
test "uleb128 known encodings" {
  // 0 -> 0x00
  assert_eq(Reader::new(b"\x00").read_uleb128(), Ok(0UL))
  // 127 -> 0x7F
  assert_eq(Reader::new(b"\x7F").read_uleb128(), Ok(127UL))
  // 128 -> 0x80 0x01
  assert_eq(Reader::new(b"\x80\x01").read_uleb128(), Ok(128UL))
  // 300 -> 0xAC 0x02
  assert_eq(Reader::new(b"\xAC\x02").read_uleb128(), Ok(300UL))
}

///|
test "uleb128 rejects 10th continuation byte" {
  let overlong = b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01"
  assert_eq(Reader::new(overlong).read_uleb128(), Err(VarintTooLong))
}

///|
test "uleb128 eof mid-value" {
  assert_eq(Reader::new(b"\x80").read_uleb128(), Err(UnexpectedEof))
  assert_eq(Reader::new(b"").read_uleb128(), Err(UnexpectedEof))
}

///|
test "uleb128 maximal values" {
  // 2^64 - 1 encodes as ff ff ff ff ff ff ff ff ff 01
  let all_ones = b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01"
  assert_eq(Reader::new(all_ones).read_uleb128(), Ok(0xFFFFFFFFFFFFFFFFUL))
  // 2^63 (needs full 10-byte width)
  assert_eq(
    Reader::new(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01").read_uleb128(),
    Ok(0x8000000000000000UL),
  )
}

///|
test "fixed-width big-endian reads" {
  let r = Reader::new(
    b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E",
  )
  assert_eq(r.read_u16_be(), Ok((0x0102).to_uint16()))
  assert_eq(r.read_u32_be(), Ok(0x03040506U))
  assert_eq(r.read_u64_be(), Ok(0x0708090A0B0C0D0EUL))
  assert_true(r.is_empty())
}

///|
test "i64_be sign preservation" {
  // -1 as two's complement 64-bit
  assert_eq(
    Reader::new(b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF").read_i64_be(),
    Ok(-1L),
  )
  // Int64 min (bit-preserving from unsigned literal)
  assert_eq(
    Reader::new(b"\x80\x00\x00\x00\x00\x00\x00\x00").read_i64_be(),
    Ok(0x8000000000000000UL.reinterpret_as_int64()),
  )
}

///|
test "truncated fixed-width read reports eof and stops" {
  let r = Reader::new(b"\x01\x02\x03")
  assert_eq(r.read_u32_be(), Err(UnexpectedEof))
  // failed read must not advance the cursor past consumed bytes
  assert_eq(r.position(), 3)
}

///|
test "read_view bounds" {
  let r = Reader::new(b"abc")
  assert_eq(r.read_view(2), Ok(b"ab"[0:2]))
  assert_eq(r.read_view(2), Err(UnexpectedEof))
  assert_eq(r.read_view(-1), Err(LengthOutOfRange))
  assert_eq(r.read_view(1), Ok(b"c"[0:1]))
}

///|
test "crc32 known vector" {
  // IEEE CRC-32 of "123456789"
  assert_eq(crc32(b"123456789"), 0xCBF43926U)
  assert_eq(crc32(b""), 0U)
}

///|
test "crc32 extend composition law" {
  let a = b"hello, "
  let b = b"moonflux world"
  let buf = Buffer::Buffer()
  buf.write_bytes(a[0:a.length()])
  buf.write_bytes(b[0:b.length()])
  assert_eq(crc32(buf.to_bytes()), crc32_extend(crc32(a), b))
}

///|
test "crc32 view matches owned" {
  let data = b"protocol frame payload \x00\xFF\x80"
  assert_eq(crc32(data), crc32_view(data[0:data.length()]))
}

///|
test "hex round trip and rejections" {
  assert_eq(hex_encode(b"\x00\x0F\xF0\xff"), "000ff0ff")
  assert_eq(hex_decode("000fF0FF"), Ok(b"\x00\x0F\xF0\xff"))
  assert_eq(hex_decode("abc"), Err(InvalidHex))
  assert_eq(hex_decode("zz"), Err(InvalidHex))
  assert_eq(hex_decode(""), Ok(b""))
}
