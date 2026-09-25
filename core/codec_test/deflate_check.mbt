// SPDX-License-Identifier: Apache-2.0
// DEFLATE tests (P25): the external anchor is Python's zlib — the
// generated vectors ARE Python's compressed output, and our decoder
// must read every container back byte-identical. The compressor's own
// output is anchored in the e2e gate, where the Python test broker
// re-inflates what we deflate.

///|
fn hex_bytes(hex : String) -> Bytes {
  match @codec.hex_decode(hex) {
    Ok(bytes) => bytes
    Err(e) => abort("bad hex in generated vectors: \{e}")
  }
}

///|
test "python zlib output inflates byte-identical (zlib and gzip containers)" {
  for case in deflate_cases {
    let data = hex_bytes(case.data_hex)
    // the zlib container, both compression levels
    match @codec.kafka_decompress(hex_bytes(case.zlib_hex), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("zlib vector \{case.name}: \{e}")
    }
    match @codec.kafka_decompress(hex_bytes(case.zlib9_hex), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("zlib9 vector \{case.name}: \{e}")
    }
    // the gzip container — what a real Kafka broker's producer emits
    match @codec.kafka_decompress(hex_bytes(case.gzip_hex), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("gzip vector \{case.name}: \{e}")
    }
    // raw DEFLATE straight from Python's compressor
    match @codec.inflate_raw(hex_bytes(case.raw_hex), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("raw vector \{case.name}: \{e}")
    }
  }
}

///|
test "our compressor's output re-inflates byte-identical" {
  for case in deflate_cases {
    let data = hex_bytes(case.data_hex)
    let compressed = @codec.deflate_raw(data)
    match @codec.inflate_raw(compressed, 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("round trip \{case.name}: \{e}")
    }
    // and through both containers, which is how it travels
    match @codec.kafka_decompress(@codec.zlib_wrap(compressed, data), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("zlib round trip \{case.name}: \{e}")
    }
    match @codec.kafka_decompress(@codec.gzip_wrap(compressed, data), 1 << 27) {
      Ok(out) => assert_true(out == data)
      Err(e) => abort("gzip round trip \{case.name}: \{e}")
    }
  }
}

///|
test "checksums match Python's reference values" {
  for case in deflate_cases {
    let data = hex_bytes(case.data_hex)
    let crc = @codec.crc32_view(data[0:data.length()])
    assert_eq(
      crc.to_int(),
      match parse_hex_int(case.crc32_hex) {
        Ok(v) => v
        Err(_) => abort("bad crc hex")
      },
    )
    let adler = @codec.adler32(data)
    assert_eq(
      adler,
      match parse_hex_int(case.adler32_hex) {
        Ok(v) => v
        Err(_) => abort("bad adler hex")
      },
    )
  }
}

///|
fn parse_hex_int(hex : String) -> Result[Int, String] {
  let mut value = 0
  for i = 0; i < hex.length(); i = i + 1 {
    let c = hex[i].to_int()
    let digit = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      return Err("bad hex digit")
    }
    value = value * 16 + digit
  }
  Ok(value)
}

///|
test "the decompression cap refuses a bomb instead of allocating" {
  // 64 KiB of zeros compresses to a few hundred bytes: inflating with
  // a 1024-byte cap must be a structured error, not an allocation
  for case in deflate_cases {
    if case.name == "zeros-64k" {
      match @codec.kafka_decompress(hex_bytes(case.gzip_hex), 1024) {
        Err(e) => assert_true("\{e}".contains("cap"))
        Ok(_) => abort("a decompression bomb was not refused")
      }
    }
  }
}

///|
test "corrupt containers are refused by what they violate" {
  let data = hex_bytes("68656c6c6f206465666c61746521") // "hello, deflate!"
  let compressed = @codec.gzip_wrap(@codec.deflate_raw(data), data)
  // flip a payload byte: the container CRC must catch it
  let corrupted = corrupt_byte(compressed, 15)
  match @codec.kafka_decompress(corrupted, 1 << 27) {
    Err(e) => assert_true("\{e}".contains("CRC") || "\{e}".contains("deflate"))
    Ok(_) => abort("a corrupted gzip payload was accepted")
  }
  // a zlib container with a broken header check is refused by name
  match @codec.kafka_decompress(hex_bytes("0078abcdabcd"), 1 << 27) {
    Err(e) =>
      assert_true("\{e}".contains("container") || "\{e}".contains("zlib"))
    Ok(_) => abort("garbage was accepted as a container")
  }
  // too-short input is a structured error
  match @codec.kafka_decompress(hex_bytes("1f"), 1 << 27) {
    Err(_) => ()
    Ok(_) => abort("a one-byte payload was accepted")
  }
}

///|
fn corrupt_byte(data : Bytes, index : Int) -> Bytes {
  let bytes : Array[Byte] = []
  for i = 0; i < data.length(); i = i + 1 {
    if i == index {
      bytes.push((data[i].to_int() ^ 0xFF).to_byte())
    } else {
      bytes.push(data[i])
    }
  }
  Bytes::from_array(bytes[:])
}
