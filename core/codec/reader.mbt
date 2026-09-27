// SPDX-License-Identifier: Apache-2.0
// moonflux — core/codec: reader cursor over immutable bytes.
//
// Bounds are checked on every read; the kernel never relies on trap
// semantics for untrusted input (AGENTS §5). All multi-byte integers
// are big-endian; variable lengths use unsigned LEB128 with a hard
// 10-byte width bound.

///|
/// Failure modes of cursor-based decoding. A closed error set: the
/// codec maps every malformed-input situation onto exactly one of
/// these cases, with no panics and no exceptions.
pub(all) suberror DecodeError {
  /// Input ended before the declared structure was complete.
  UnexpectedEof
  /// A varint occupied more bytes than its 10-byte width bound.
  VarintTooLong
  /// A length or count field exceeds the plausible frame bounds.
  LengthOutOfRange
  /// Hex input contains a non-hex digit or has odd length.
  InvalidHex
} derive(Debug, Eq)

///|
pub impl Show for DecodeError with fn output(self, logger) {
  let s = match self {
    UnexpectedEof => "UnexpectedEof"
    VarintTooLong => "VarintTooLong"
    LengthOutOfRange => "LengthOutOfRange"
    InvalidHex => "InvalidHex"
  }
  logger.write_string(s)
}

///|
/// A byte-cursor over an immutable byte string. The cursor never
/// aliases mutable state: `Bytes` is immutable, so views handed out
/// by `read_view` remain valid for the lifetime of the source.
pub struct Reader {
  bytes : Bytes
  mut pos : Int
}

///|
/// Creates a cursor positioned at the start of `bytes`.
pub fn Reader::new(bytes : Bytes) -> Reader {
  Reader::{ bytes, pos: 0, }
}

///|
/// Number of bytes left before the cursor hits the end.
pub fn Reader::remaining(self : Reader) -> Int {
  self.bytes.length() - self.pos
}

///|
/// Current absolute position within the source bytes.
pub fn Reader::position(self : Reader) -> Int {
  self.pos
}

///|
/// True when the cursor has consumed the whole input.
pub fn Reader::is_empty(self : Reader) -> Bool {
  self.pos >= self.bytes.length()
}

///|
/// Reads one byte.
pub fn Reader::read_byte(self : Reader) -> Result[Byte, DecodeError] {
  if self.remaining() < 1 {
    return Err(UnexpectedEof)
  }
  let b = self.bytes[self.pos]
  self.pos += 1
  Ok(b)
}

///|
/// Peeks one byte without consuming it.
pub fn Reader::peek_byte(self : Reader) -> Result[Byte, DecodeError] {
  if self.remaining() < 1 {
    return Err(UnexpectedEof)
  }
  Ok(self.bytes[self.pos])
}

///|
/// Reads `n` bytes as a zero-copy view into the source.
pub fn Reader::read_view(
  self : Reader,
  n : Int,
) -> Result[BytesView, DecodeError] {
  if n < 0 {
    return Err(LengthOutOfRange)
  }
  if self.remaining() < n {
    return Err(UnexpectedEof)
  }
  let view = self.bytes[self.pos:self.pos + n]
  self.pos += n
  Ok(view)
}

///|
/// Reads `n` bytes as an owned copy.
pub fn Reader::read_bytes(self : Reader, n : Int) -> Result[Bytes, DecodeError] {
  match self.read_view(n) {
    Ok(view) => Ok(view.to_owned())
    Err(e) => Err(e)
  }
}

///|
/// Reads an unsigned LEB128 value (at most 10 bytes, full UInt64
/// range). Rejects over-long encodings that pad with continuation
/// bits beyond the width bound.
pub fn Reader::read_uleb128(self : Reader) -> Result[UInt64, DecodeError] {
  let mut result : UInt64 = 0UL
  let mut shift = 0
  let mut count = 0
  while count < 10 {
    let b = match self.read_byte() {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    count += 1
    let low : UInt64 = (b.to_int() & 0x7F).to_uint64()
    result = result | (low << shift)
    if (b.to_int() & 0x80) == 0 {
      return Ok(result)
    }
    shift += 7
  }
  Err(VarintTooLong)
}

///|
/// Reads an unsigned LEB128 length and validates it fits in `Int`
/// (32-bit on every MoonBit backend) before returning it.
pub fn Reader::read_uleb128_len(self : Reader) -> Result[Int, DecodeError] {
  let v = match self.read_uleb128() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if v > 0x7FFFFFFFUL {
    return Err(LengthOutOfRange)
  }
  Ok(v.to_int())
}

///|
/// Reads a 16-bit big-endian unsigned integer.
pub fn Reader::read_u16_be(self : Reader) -> Result[UInt16, DecodeError] {
  let hi = match self.read_byte() {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let lo = match self.read_byte() {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  Ok(((hi.to_int() << 8) | lo.to_int()).to_uint16())
}

///|
/// Reads a 32-bit big-endian unsigned integer.
pub fn Reader::read_u32_be(self : Reader) -> Result[UInt, DecodeError] {
  let mut v : UInt = 0U
  for _i in 0..<4 {
    let b = match self.read_byte() {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    v = (v << 8) | b.to_int().reinterpret_as_uint()
  }
  Ok(v)
}

///|
/// Reads a 64-bit big-endian unsigned integer.
pub fn Reader::read_u64_be(self : Reader) -> Result[UInt64, DecodeError] {
  let mut v : UInt64 = 0UL
  for _i in 0..<8 {
    let b = match self.read_byte() {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    v = (v << 8) | b.to_int().to_uint64()
  }
  Ok(v)
}

///|
/// Reads a 64-bit big-endian signed integer (bit-preserving).
pub fn Reader::read_i64_be(self : Reader) -> Result[Int64, DecodeError] {
  let mut v : Int64 = 0L
  for _i in 0..<8 {
    let b = match self.read_byte() {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    v = (v << 8) | b.to_int().to_int64()
  }
  Ok(v)
}
