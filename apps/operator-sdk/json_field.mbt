// SPDX-License-Identifier: Apache-2.0
// Reading ONE field out of a JSON record without parsing the document.
//
// Why this exists: a guest operator that needs "the value of `event_name`"
// used to call the full JSON parser per record, and the wasm fuel budget is
// an honest limit — 183 such records exhausted the internal tier's 50M
// instructions (measured while porting the Unreal Engine counter, which is
// exactly what the budget is for: it noticed). One field, read with a
// structure-aware scan, costs a small fraction of that.
//
// "Structure-aware" is the load-bearing word. A substring search for
// `"event_name"` would be fooled by the key appearing inside a string value
// (an `attributes` entry whose value is `"event_name"`), and the difference
// between a scanner that tracks strings/escapes/depth and one that does not
// is the difference between correct and correct-until-it-is-not.
//
// What it does NOT do: nested paths. `operation.Transfer.sender.iban` needs a
// parser, and the operators that need nesting (the bank event normalizer) keep
// using one. That is a deliberate split: cheap for the common case, explicit
// about the expensive one.

///|
/// One scalar JSON member.
pub(all) enum JsonScalar {
  ScalarText(String)
  ScalarNumber(Double)
  ScalarBool(Bool)
  ScalarNull
} derive(Debug, Eq)

///|
fn jf_is_ws(b : Byte) -> Bool {
  b == b' ' || b == b'\t' || b == b'\n' || b == b'\r'
}

///|
fn jf_skip_ws(data : Bytes, start : Int32) -> Int32 {
  let mut i = start
  while i < data.length() && jf_is_ws(data[i]) {
    i = i + 1
  }
  i
}

///|
/// Skips a JSON string starting at the opening quote; returns the offset just
/// past the closing quote. Unknown escapes are skipped as two bytes: the
/// caller that *reads* a string validates them, a skipper only needs to know
/// where the string ends.
fn jf_skip_string(data : Bytes, start : Int32) -> Result[Int32, String] {
  let n = data.length()
  let mut i = start + 1
  while i < n {
    match data[i] {
      b'\\' => i = i + 2
      b'"' => return Ok(i + 1)
      _ => i = i + 1
    }
  }
  Err("unterminated JSON string")
}

///|
/// Appends one code point to a UTF-8 buffer.
fn jf_push_codepoint(out : @buffer.Buffer, cp : Int32) -> Unit {
  if cp < 0x80 {
    out.write_byte(cp.to_byte())
  } else if cp < 0x800 {
    out.write_byte((0xC0 | (cp >> 6)).to_byte())
    out.write_byte((0x80 | (cp & 0x3F)).to_byte())
  } else if cp < 0x10000 {
    out.write_byte((0xE0 | (cp >> 12)).to_byte())
    out.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
    out.write_byte((0x80 | (cp & 0x3F)).to_byte())
  } else {
    out.write_byte((0xF0 | (cp >> 18)).to_byte())
    out.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
    out.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
    out.write_byte((0x80 | (cp & 0x3F)).to_byte())
  }
}

///|
fn jf_hex_digit(b : Byte) -> Int32? {
  if b >= b'0' && b <= b'9' {
    Some((b - b'0').to_int())
  } else if b >= b'a' && b <= b'f' {
    Some((b - b'a').to_int() + 10)
  } else if b >= b'A' && b <= b'F' {
    Some((b - b'A').to_int() + 10)
  } else {
    None
  }
}

///|
/// Reads (and unescapes) a JSON string starting at the opening quote.
fn jf_read_string(
  data : Bytes,
  start : Int32,
) -> Result[(String, Int32), String] {
  let n = data.length()
  let out = @buffer.Buffer::Buffer()
  let mut i = start + 1
  while i < n {
    let b = data[i]
    if b == b'"' {
      return Ok((@utf8.decode_lossy(out.to_bytes()), i + 1))
    }
    if b != b'\\' {
      out.write_byte(b)
      i = i + 1
      continue
    }
    if i + 1 >= n {
      return Err("dangling escape in JSON string")
    }
    let esc = data[i + 1]
    i = i + 2
    match esc {
      b'"' => out.write_byte(b'"')
      b'\\' => out.write_byte(b'\\')
      b'/' => out.write_byte(b'/')
      b'b' => out.write_byte(0x08)
      b'f' => out.write_byte(0x0C)
      b'n' => out.write_byte(b'\n')
      b'r' => out.write_byte(b'\r')
      b't' => out.write_byte(b'\t')
      b'u' => {
        if i + 4 > n {
          return Err("truncated \\u escape")
        }
        let mut cp = 0
        for k in 0..<4 {
          let digit = match jf_hex_digit(data[i + k]) {
            Some(d) => d
            None => return Err("\\u escape is not hex")
          }
          cp = (cp << 4) | digit
        }
        i = i + 4
        // a high surrogate must be followed by its low half; a lone
        // surrogate is not a code point and is refused rather than encoded
        if cp >= 0xD800 && cp <= 0xDBFF {
          if i + 6 > n || data[i] != b'\\' || data[i + 1] != b'u' {
            return Err("high surrogate without a low surrogate")
          }
          let mut low = 0
          for k in 0..<4 {
            let digit = match jf_hex_digit(data[i + 2 + k]) {
              Some(d) => d
              None => return Err("\\u escape is not hex")
            }
            low = (low << 4) | digit
          }
          if low < 0xDC00 || low > 0xDFFF {
            return Err("high surrogate without a low surrogate")
          }
          i = i + 6
          jf_push_codepoint(
            out,
            0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00),
          )
        } else if cp >= 0xDC00 && cp <= 0xDFFF {
          return Err("lone low surrogate")
        } else {
          jf_push_codepoint(out, cp)
        }
      }
      _ => return Err("unknown escape in JSON string")
    }
  }
  Err("unterminated JSON string")
}

///|
fn jf_match_token(data : Bytes, start : Int32, token : String) -> Bool {
  if start + token.length() > data.length() {
    return false
  }
  for k in 0..<token.length() {
    if data[start + k] != token.unsafe_charcode_at(k).to_byte() {
      return false
    }
  }
  true
}

///|
/// Skips one JSON value starting at `start`; returns the offset after it.
fn jf_skip_value(data : Bytes, start : Int32) -> Result[Int32, String] {
  let n = data.length()
  if start >= n {
    return Err("truncated JSON value")
  }
  match data[start] {
    b'"' => jf_skip_string(data, start)
    b'{' | b'[' => {
      let mut depth = 0
      let mut i = start
      while i < n {
        match data[i] {
          b'"' =>
            i = match jf_skip_string(data, i) {
              Ok(j) => j
              Err(e) => return Err(e)
            }
          b'{' | b'[' => {
            depth = depth + 1
            i = i + 1
          }
          b'}' | b']' => {
            depth = depth - 1
            i = i + 1
            if depth == 0 {
              return Ok(i)
            }
          }
          _ => i = i + 1
        }
      }
      Err("unbalanced JSON value")
    }
    _ => {
      let mut i = start
      while i < n &&
            !jf_is_ws(data[i]) &&
            data[i] != b',' &&
            data[i] != b'}' &&
            data[i] != b']' {
        i = i + 1
      }
      Ok(i)
    }
  }
}

///|
/// Reads one **top-level** scalar member of a JSON object.
///
/// - `Ok(None)`: the member is not there
/// - `Ok(Some(scalar))`: its value
/// - `Err`: not a JSON object, malformed, or the member is not a scalar
///   (an object or an array). Absence and "not a scalar" are different
///   answers on purpose: the first is data, the second is a schema mistake.
pub fn json_field(value : Bytes, field : String) -> Result[JsonScalar?, String] {
  let data = value
  let n = data.length()
  let mut i = jf_skip_ws(data, 0)
  if i >= n || data[i] != b'{' {
    return Err("value is not a JSON object")
  }
  i = jf_skip_ws(data, i + 1)
  while true {
    if i >= n {
      return Err("truncated JSON object")
    }
    if data[i] == b'}' {
      return Ok(None)
    }
    if data[i] != b'"' {
      return Err("JSON object member is not a string key")
    }
    let (key, after_key) = match jf_read_string(data, i) {
      Ok(pair) => pair
      Err(e) => return Err(e)
    }
    i = jf_skip_ws(data, after_key)
    if i >= n || data[i] != b':' {
      return Err("JSON member has no value")
    }
    i = jf_skip_ws(data, i + 1)
    if i >= n {
      return Err("truncated JSON value")
    }
    if key == field {
      match data[i] {
        b'"' =>
          match jf_read_string(data, i) {
            Ok((text, _)) => return Ok(Some(ScalarText(text)))
            Err(e) => return Err(e)
          }
        b'{' | b'[' => return Err("field \{field} is not a scalar")
        b't' =>
          if jf_match_token(data, i, "true") {
            return Ok(Some(ScalarBool(true)))
          } else {
            return Err("field \{field} is not a valid JSON value")
          }
        b'f' =>
          if jf_match_token(data, i, "false") {
            return Ok(Some(ScalarBool(false)))
          } else {
            return Err("field \{field} is not a valid JSON value")
          }
        b'n' =>
          if jf_match_token(data, i, "null") {
            return Ok(Some(ScalarNull))
          } else {
            return Err("field \{field} is not a valid JSON value")
          }
        _ => {
          let start = i
          while i < n &&
                !jf_is_ws(data[i]) &&
                data[i] != b',' &&
                data[i] != b'}' &&
                data[i] != b']' {
            i = i + 1
          }
          let text = @utf8.decode_lossy(data[start:i])
          match (try? @string.parse_double(text)) {
            Ok(d) => return Ok(Some(ScalarNumber(d)))
            Err(_) => return Err("field \{field} is not a number")
          }
        }
      }
    }
    i = match jf_skip_value(data, i) {
      Ok(j) => j
      Err(e) => return Err(e)
    }
    i = jf_skip_ws(data, i)
    if i < n && data[i] == b',' {
      i = jf_skip_ws(data, i + 1)
    }
  }
  Ok(None)
}
