// Blackbox tests for moonflux/core/codec — only the public contract.
// Imports are declared in moon.pkg; no import blocks in .mbt files.

///|
test "uleb128 decode agrees with core Buffer encoding" {
  // Cross-check our reader against moonbitlang/core's own LEB128
  // encoder over boundary values: two independent implementations
  // of the same standard must agree byte-for-byte.
  let values : Array[UInt64] = [
    0UL, 1UL, 127UL, 128UL, 300UL, 16383UL, 16384UL, 0xFFFFFFFFUL, 0x7FFFFFFFUL,
    0x80000000UL, 0xFFFFFFFFFFFFFFFFUL, 0x8000000000000000UL,
  ]
  for v in values {
    let buf = @buffer.Buffer::Buffer()
    buf.write_leb128(v)
    let bytes = buf.to_bytes()
    assert_eq(@codec.Reader::new(bytes).read_uleb128(), Ok(v))
  }
}

///|
test "uleb128 len rejects values beyond Int range" {
  // 2^31 does not fit a 32-bit Int length
  let buf = @buffer.Buffer::Buffer()
  buf.write_leb128(0x80000000UL)
  assert_eq(
    @codec.Reader::new(buf.to_bytes()).read_uleb128_len(),
    Err(@codec.LengthOutOfRange),
  )
}

///|
test "crc32 extension chain matches one-shot over concatenation" {
  let parts : Array[Bytes] = [
    b"", b"a", b"moon", b"flux", b"record batch frame", b"\x00\x01\xFF",
  ]
  for a in parts {
    for b in parts {
      let joined = @buffer.Buffer::Buffer()
      joined.write_bytes(a[0:a.length()])
      joined.write_bytes(b[0:b.length()])
      assert_eq(
        @codec.crc32(joined.to_bytes()),
        @codec.crc32_extend(@codec.crc32(a), b),
      )
    }
  }
}

///|
test "hex round trip preserves arbitrary bytes" {
  let samples : Array[Bytes] = [
    b"", b"\x00", b"\xFF", b"deadbeef", b"\x01\x02\x03\x04\x05",
  ]
  for s in samples {
    assert_eq(@codec.hex_decode(@codec.hex_encode(s)), Ok(s))
  }
  assert_eq(@codec.hex_decode("g0"), Err(@codec.InvalidHex))
}
