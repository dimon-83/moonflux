// SPDX-License-Identifier: Apache-2.0
// moonflux — core/codec: lowercase hex encoding/decoding. Used by
// golden-vector tooling and protocol crosscheck output.

///|
/// Encodes bytes as a lowercase hex string.
pub fn hex_encode(data : Bytes) -> String {
  let sb = StringBuilder::new(size_hint=data.length() * 2)
  for i in 0..<data.length() {
    let b = data[i].to_int()
    sb.write_char(digit_char(b >> 4))
    sb.write_char(digit_char(b & 0x0F))
  }
  sb.to_string()
}

///|
fn digit_char(v : Int) -> Char {
  if v < 10 {
    (v + 48).unsafe_to_char() // '0'
  } else {
    (v - 10 + 97).unsafe_to_char() // 'a'
  }
}

///|
fn hex_value(c : UInt16) -> Int? {
  if c >= 48 && c <= 57 {
    Some(c.to_int() - 48)
  } else if c >= 97 && c <= 102 {
    Some(c.to_int() - 87)
  } else if c >= 65 && c <= 70 {
    Some(c.to_int() - 55)
  } else {
    None
  }
}

///|
/// Decodes a hex string (either case) into bytes. Rejects odd length
/// and non-hex digits with `InvalidHex`.
pub fn hex_decode(s : String) -> Result[Bytes, DecodeError] {
  let n = s.length()
  if n % 2 != 0 {
    return Err(InvalidHex)
  }
  let out : FixedArray[Byte] = FixedArray::make(n / 2, b'\x00')
  let mut i = 0
  while i < n {
    let hi = match hex_value(s[i]) {
      Some(v) => v
      None => return Err(InvalidHex)
    }
    let lo = match hex_value(s[i + 1]) {
      Some(v) => v
      None => return Err(InvalidHex)
    }
    out[i / 2] = ((hi << 4) | lo).to_byte()
    i += 2
  }
  let arr : Array[Byte] = []
  for k in 0..<out.length() {
    arr.push(out[k])
  }
  Ok(Bytes::from_array(arr[:]))
}
