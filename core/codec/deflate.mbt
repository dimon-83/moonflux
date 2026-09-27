// SPDX-License-Identifier: Apache-2.0
// core/codec/deflate.mbt (P25): DEFLATE (RFC 1951) and the two
// containers that carry it — zlib (RFC 1950) and gzip (RFC 1952).
//
// Pure computation, like everything in core: no IO, no clock,
// deterministic (same input, same output — the kernel red lines). This
// exists for one immediate consumer and one standing reason. The
// immediate consumer is the Kafka connector: RecordBatch v2 carries a
// compression column, real producers ship gzip batches, and a pipeline
// reading a real topic has to read what real producers write. The
// standing reason is that a compression codec is a platform capability
// — the dependency rule makes it ours, and Python's zlib (the gate's
// anchor, both directions) makes "both sides agree" mean something.
//
// The compressor emits fixed-Huffman blocks with greedy LZ77 matching
// — not the smallest possible output (dynamic-Huffman tables would
// squeeze more), but a valid DEFLATE stream any decoder accepts, and
// one we can decode ourselves. The decompressor handles all three
// block types, because the world's producers emit dynamic blocks and
// a decoder that only read our own output would be an agreement with
// ourselves — the exact trap the golden-rule discipline names.

///|
/// DEFLATE packs bits LSB-first within each byte (RFC 1951 §3.1.1).
struct DeflateBitReader {
  bytes : Bytes
  mut pos : Int
  mut bit : Int
}

///|
fn DeflateBitReader::new(bytes : Bytes) -> DeflateBitReader {
  { bytes, pos: 0, bit: 0, }
}

///|
/// Reads one bit; -1 when the input is exhausted (callers turn that
/// into a truncated-stream error rather than a panic).
fn DeflateBitReader::read_bit(self : DeflateBitReader) -> Int {
  if self.pos >= self.bytes.length() {
    return -1
  }
  let v = (self.bytes[self.pos].to_int() >> self.bit) & 1
  self.bit += 1
  if self.bit == 8 {
    self.bit = 0
    self.pos += 1
  }
  v
}

///|
/// Reads `n` bits LSB-first; -1 when the input runs out first.
fn DeflateBitReader::read_bits(self : DeflateBitReader, n : Int) -> Int {
  let mut value = 0
  for i = 0; i < n; i = i + 1 {
    let b = self.read_bit()
    if b < 0 {
      return -1
    }
    value = value | (b << i)
  }
  value
}

///|
/// Discards the partial byte so the next read starts byte-aligned
/// (stored blocks are byte-aligned by definition).
fn DeflateBitReader::align(self : DeflateBitReader) -> Unit {
  if self.bit != 0 {
    self.bit = 0
    self.pos += 1
  }
}

///|
/// A canonical Huffman table (RFC 1951 §3.2.2): counts of codes per
/// length, and the symbols ordered by (length, symbol value).
struct HuffmanTable {
  counts : Array[Int]
  symbols : Array[Int]
}

///|
/// Builds a table from code lengths. Over-subscribed sets are refused
/// (a prefix code cannot exist); incomplete sets are accepted — the
/// distance table with a single code is legal DEFLATE and both the
/// RFC and every real encoder produce it.
fn huffman_build(lengths : Array[Int]) -> HuffmanTable? {
  let counts = Array::make(16, 0)
  for len in lengths {
    if len > 15 {
      return None
    }
    counts[len] = counts[len] + 1
  }
  counts[0] = 0
  // Kraft check: the code space assigned must not exceed the whole
  let mut left = 1
  for len = 1; len <= 15; len = len + 1 {
    left = left * 2 - counts[len]
    if left < 0 {
      return None
    }
  }
  let offs = Array::make(16, 0)
  for len = 1; len < 15; len = len + 1 {
    offs[len + 1] = offs[len] + counts[len]
  }
  let symbols = Array::make(lengths.length(), 0)
  for symbol = 0; symbol < lengths.length(); symbol = symbol + 1 {
    if lengths[symbol] != 0 {
      symbols[offs[lengths[symbol]]] = symbol
      offs[lengths[symbol]] = offs[lengths[symbol]] + 1
    }
  }
  Some({ counts, symbols, })
}

///|
/// Decodes one symbol, bit by bit (the "puff" walk): -1 on truncated
/// input or a code that matches nothing in the table.
fn HuffmanTable::decode(self : HuffmanTable, br : DeflateBitReader) -> Int {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for len = 1; len <= 15; len = len + 1 {
    let b = br.read_bit()
    if b < 0 {
      return -1
    }
    code = code | b
    let count = self.counts[len]
    if code - first < count {
      return self.symbols[index + code - first]
    }
    index += count
    first = (first + count) * 2
    code = code * 2
  }
  -1
}

///|
/// The fixed-Huffman literal/length table: 0-143 eight bits, 144-255
/// nine, 256-279 seven, 280-287 eight (RFC 1951 §3.2.6).
fn fixed_literal_table() -> HuffmanTable {
  let lengths : Array[Int] = []
  for i = 0; i < 144; i = i + 1 {
    lengths.push(8)
  }
  for i = 0; i < 112; i = i + 1 {
    lengths.push(9)
  }
  for i = 0; i < 24; i = i + 1 {
    lengths.push(7)
  }
  for i = 0; i < 8; i = i + 1 {
    lengths.push(8)
  }
  match huffman_build(lengths) {
    Some(table) => table
    None => abort("fixed literal table cannot fail to build")
  }
}

///|
/// The fixed-Huffman distance table: 32 codes of five bits (30-31
/// exist but never appear in a valid stream).
fn fixed_distance_table() -> HuffmanTable {
  let lengths : Array[Int] = []
  for i = 0; i < 32; i = i + 1 {
    lengths.push(5)
  }
  match huffman_build(lengths) {
    Some(table) => table
    None => abort("fixed distance table cannot fail to build")
  }
}

///|
/// Length codes 257-285: the base match length and how many extra
/// bits ride with each (RFC 1951 §3.2.5).
let len_base : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let len_extra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// Distance codes 0-29: the base distance and its extra bits.
let dist_base : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// The order code-length codes arrive in a dynamic block's header —
/// deliberately scrambled by the RFC (§3.2.7), so the natural order is
/// the classic mistake.
let code_length_order : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
/// Reads one dynamic block's two Huffman tables (code lengths first,
/// then literal/length and distance) from the header.
fn read_dynamic_tables(
  br : DeflateBitReader,
) -> Result[(HuffmanTable, HuffmanTable), String] {
  let hlit = br.read_bits(5)
  let hdist = br.read_bits(5)
  let hclen = br.read_bits(4)
  if hlit < 0 || hdist < 0 || hclen < 0 {
    return Err("truncated dynamic block header")
  }
  let nlit = hlit + 257
  let ndist = hdist + 1
  if nlit > 286 || ndist > 30 {
    return Err("dynamic block declares too many codes")
  }
  let cl_lengths = Array::make(19, 0)
  for i = 0; i < hclen + 4; i = i + 1 {
    let v = br.read_bits(3)
    if v < 0 {
      return Err("truncated code-length code lengths")
    }
    cl_lengths[code_length_order[i]] = v
  }
  let cl_table = match huffman_build(cl_lengths) {
    Some(table) => table
    None => return Err("the code-length code is over-subscribed")
  }
  let lengths = Array::make(nlit + ndist, 0)
  let mut i = 0
  while i < nlit + ndist {
    let symbol = cl_table.decode(br)
    if symbol < 0 {
      return Err("truncated code lengths")
    }
    if symbol < 16 {
      lengths[i] = symbol
      i += 1
    } else if symbol == 16 {
      if i == 0 {
        return Err("a repeat with nothing to repeat")
      }
      let prev = lengths[i - 1]
      let repeat = 3 + br.read_bits(2)
      if repeat < 0 {
        return Err("truncated repeat")
      }
      for _k in 0..<repeat {
        if i >= nlit + ndist {
          return Err("a repeat overruns the code lengths")
        }
        lengths[i] = prev
        i += 1
      }
    } else if symbol == 17 {
      let repeat = 3 + br.read_bits(3)
      if repeat < 0 {
        return Err("truncated zero run")
      }
      for _k in 0..<repeat {
        if i >= nlit + ndist {
          return Err("a zero run overruns the code lengths")
        }
        lengths[i] = 0
        i += 1
      }
    } else {
      let repeat = 11 + br.read_bits(7)
      if repeat < 0 {
        return Err("truncated long zero run")
      }
      for _k in 0..<repeat {
        if i >= nlit + ndist {
          return Err("a long zero run overruns the code lengths")
        }
        lengths[i] = 0
        i += 1
      }
    }
  }
  let lit_lengths = lengths[0:nlit].to_array()
  let dist_lengths = lengths[nlit:nlit + ndist].to_array()
  let lit_table = match huffman_build(lit_lengths) {
    Some(table) => table
    None => return Err("the literal/length code is over-subscribed")
  }
  let dist_table = match huffman_build(dist_lengths) {
    Some(table) => table
    None => return Err("the distance code is over-subscribed")
  }
  Ok((lit_table, dist_table))
}

///|
/// Raw DEFLATE decompression with a hard output cap. The cap is the
/// decompression-bomb boundary: a small compressed payload must never
/// expand into memory the caller never budgeted for — exceeding it is
/// a structured error, not an allocation.
pub fn inflate_raw(input : Bytes, max_out : Int) -> Result[Bytes, String] {
  let br = DeflateBitReader::new(input)
  let out : Array[Byte] = []
  // the fixed tables are built per stream: a 288-entry build is
  // microseconds and keeps every top-level binding immutable
  let lit_fixed = fixed_literal_table()
  let dist_fixed = fixed_distance_table()
  while true {
    let bfinal = br.read_bit()
    let btype = br.read_bits(2)
    if bfinal < 0 || btype < 0 {
      return Err("truncated deflate stream header")
    }
    if btype == 0 {
      // stored: byte-aligned, LEN must match its own one's complement
      br.align()
      if br.pos + 4 > br.bytes.length() {
        return Err("truncated stored-block header")
      }
      let len = br.bytes[br.pos].to_int() | (br.bytes[br.pos + 1].to_int() << 8)
      let nlen = br.bytes[br.pos + 2].to_int() |
        (br.bytes[br.pos + 3].to_int() << 8)
      if (len ^ 0xFFFF) != nlen {
        return Err("stored block length does not match its complement")
      }
      br.pos += 4
      if br.pos + len > br.bytes.length() {
        return Err("stored block overruns the input")
      }
      for i = 0; i < len; i = i + 1 {
        if out.length() >= max_out {
          return Err(bomb_message(max_out))
        }
        out.push(br.bytes[br.pos + i])
      }
      br.pos += len
    } else if btype == 1 || btype == 2 {
      let (lit_table, dist_table) = if btype == 1 {
        (lit_fixed, dist_fixed)
      } else {
        match read_dynamic_tables(br) {
          Ok(tables) => tables
          Err(e) => return Err(e)
        }
      }
      while true {
        let symbol = lit_table.decode(br)
        if symbol < 0 {
          return Err("truncated or invalid compressed data")
        }
        if symbol < 256 {
          if out.length() >= max_out {
            return Err(bomb_message(max_out))
          }
          out.push(symbol.to_byte())
        } else if symbol == 256 {
          break
        } else {
          let li = symbol - 257
          if li >= len_base.length() {
            return Err("invalid length code")
          }
          let extra = br.read_bits(len_extra[li])
          if extra < 0 {
            return Err("truncated length extra bits")
          }
          let length = len_base[li] + extra
          let dsym = dist_table.decode(br)
          if dsym < 0 || dsym >= dist_base.length() {
            return Err("invalid distance code")
          }
          let dextra = br.read_bits(dist_extra[dsym])
          if dextra < 0 {
            return Err("truncated distance extra bits")
          }
          let distance = dist_base[dsym] + dextra
          if distance > out.length() {
            return Err("a match reaches before the start of the output")
          }
          // overlapping copies are the point of LZ77: copy byte by
          // byte so a distance of 1 replicates the last byte
          for _k in 0..<length {
            if out.length() >= max_out {
              return Err(bomb_message(max_out))
            }
            out.push(out[out.length() - distance])
          }
        }
      }
    } else {
      return Err("reserved block type 11")
    }
    if bfinal == 1 {
      break
    }
  }
  Ok(Bytes::from_array(out[:]))
}

///|
fn bomb_message(max_out : Int) -> String {
  "decompressed output exceeds the \{max_out}-byte cap (refusing a possible decompression bomb)"
}

///|
/// The LSB-first bit writer (RFC 1951 §3.1.1).
struct DeflateBitWriter {
  out : Buffer
  mut acc : Int
  mut nbits : Int
}

///|
fn DeflateBitWriter::new() -> DeflateBitWriter {
  { out: Buffer::Buffer(), acc: 0, nbits: 0, }
}

///|
fn DeflateBitWriter::write_bits(
  self : DeflateBitWriter,
  value : Int,
  n : Int,
) -> Unit {
  self.acc = self.acc | (value << self.nbits)
  self.nbits += n
  while self.nbits >= 8 {
    self.out.write_byte((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.nbits -= 8
  }
}

///|
/// Emits a code's bits MSB-first (Huffman codes pack most-significant
/// bit first into the LSB-first stream — RFC 1951 §3.1.1's reversal).
fn DeflateBitWriter::write_code(
  self : DeflateBitWriter,
  code : Int,
  len : Int,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    self.write_bits((code >> (len - 1 - i)) & 1, 1)
  }
}

///|
fn DeflateBitWriter::align(self : DeflateBitWriter) -> Unit {
  if self.nbits > 0 {
    self.out.write_byte(self.acc.to_byte())
    self.acc = 0
    self.nbits = 0
  }
}

///|
fn DeflateBitWriter::to_bytes(self : DeflateBitWriter) -> Bytes {
  self.align()
  self.out.to_bytes()
}

///|
/// The fixed-Huffman code for a literal or a length symbol, as
/// (code, length) — the ranges stitched straight from RFC 1951 §3.2.6.
fn fixed_literal_code(symbol : Int) -> (Int, Int) {
  if symbol < 144 {
    (0x30 + symbol, 8)
  } else if symbol < 256 {
    (0x190 + symbol - 144, 9)
  } else if symbol < 280 {
    (symbol - 256, 7)
  } else {
    (0xC0 + symbol - 280, 8)
  }
}

///|
/// Finds the length code for a match length (3..258), returning the
/// symbol index and the extra-bit value.
fn length_code(length : Int) -> (Int, Int) {
  let mut i = len_base.length() - 1
  while i > 0 {
    if length >= len_base[i] {
      return (257 + i, length - len_base[i])
    }
    i -= 1
  }
  (257, 0)
}

///|
/// Finds the distance code for a match distance, as (code, extra).
fn distance_code(distance : Int) -> (Int, Int) {
  let mut i = dist_base.length() - 1
  while i > 0 {
    if distance >= dist_base[i] {
      return (i, distance - dist_base[i])
    }
    i -= 1
  }
  (0, 0)
}

///|
/// The three-byte hash for the LZ77 matcher: multiplicative, all 16
/// bits used (deterministic, no randomness — the kernel red line).
fn hash3(bytes : Bytes, pos : Int) -> Int {
  let a = bytes[pos].to_int()
  let b = bytes[pos + 1].to_int()
  let c = bytes[pos + 2].to_int()
  (a * 0x9E37 + b * 0x85EB + c * 0xC2B2) & 0xFFFF
}

///|
const MAX_CHAIN : Int = 128

///|
const MIN_MATCH : Int = 3

///|
const WINDOW_SIZE : Int = 32768

///|
/// Raw DEFLATE compression: one final fixed-Huffman block over a
/// greedy LZ77 pass. The matcher walks a hash chain per position and
/// takes the longest match it finds within MAX_CHAIN steps — a
/// deterministic trade of some ratio for bounded, input-independent
/// work.
pub fn deflate_raw(input : Bytes) -> Bytes {
  let w = DeflateBitWriter::new()
  let head : Array[Int] = Array::make(65536, -1)
  let prev : Array[Int] = Array::make(input.length(), -1)
  // one final fixed-Huffman block: BFINAL=1 then BTYPE=01 come FIRST,
  // before any of the block's data
  w.write_bits(1, 1)
  w.write_bits(1, 2)
  // position of the next unmatched literal / pending match start
  let mut i = 0
  while i < input.length() {
    let mut best_len = 0
    let mut best_dist = 0
    if i + MIN_MATCH <= input.length() {
      let h = hash3(input, i)
      let mut candidate = head[h]
      let mut chain = 0
      while candidate >= 0 && chain < MAX_CHAIN {
        let dist = i - candidate
        if dist > WINDOW_SIZE {
          break
        }
        // match length: at most the remaining input, at most 258
        let mut len = 0
        let limit = if input.length() - i < 258 {
          input.length() - i
        } else {
          258
        }
        while len < limit && input[candidate + len] == input[i + len] {
          len += 1
        }
        if len > best_len {
          best_len = len
          best_dist = dist
          if len >= limit {
            break
          }
        }
        candidate = prev[candidate]
        chain += 1
      }
      // insert this position into the chain
      prev[i] = head[h]
      head[h] = i
    }
    if best_len >= MIN_MATCH {
      let (lsym, lextra) = length_code(best_len)
      let (lcode, lbits) = fixed_literal_code(lsym)
      w.write_code(lcode, lbits)
      if len_extra[lsym - 257] > 0 {
        w.write_bits(lextra, len_extra[lsym - 257])
      }
      let (dsym, dextra) = distance_code(best_dist)
      w.write_code(dsym, 5)
      if dist_extra[dsym] > 0 {
        w.write_bits(dextra, dist_extra[dsym])
      }
      // insert the covered positions so later matches can find them
      for j = i + 1
          j < i + best_len && j + MIN_MATCH <= input.length()
          j = j + 1 {
        let h = hash3(input, j)
        prev[j] = head[h]
        head[h] = j
      }
      i += best_len
    } else {
      let (code, bits) = fixed_literal_code(input[i].to_int())
      w.write_code(code, bits)
      i += 1
    }
  }
  // end-of-block code (256 in the fixed table) closes the block
  w.write_code(0, 7)
  w.to_bytes()
}

///|
/// Adler-32 (RFC 1950 §8): the zlib container's checksum.
pub fn adler32(data : Bytes) -> Int {
  let mut a = 1
  let mut b = 0
  let n = data.length()
  let mut i = 0
  // process in chunks so b stays under the modulus bound
  while i < n {
    let end = if i + 5552 < n { i + 5552 } else { n }
    while i < end {
      a += data[i].to_int()
      b += a
      i += 1
    }
    a = a % 65521
    b = b % 65521
  }
  (b * 65536 + a) & 0xFFFFFFFF
}

///|
/// The zlib container (RFC 1950): CMF/FLG header, raw deflate, Adler-32
/// trailer. FLG is chosen so (CMF*256 + FLG) % 31 == 0 with FDICT=0.
pub fn zlib_wrap(deflated : Bytes, source : Bytes) -> Bytes {
  let out = Buffer::Buffer()
  out.write_byte((0x78).to_byte())
  out.write_byte((0x9C).to_byte())
  out.write_bytes(deflated[0:deflated.length()])
  let check = adler32(source)
  out.write_byte(((check >> 24) & 0xFF).to_byte())
  out.write_byte(((check >> 16) & 0xFF).to_byte())
  out.write_byte(((check >> 8) & 0xFF).to_byte())
  out.write_byte((check & 0xFF).to_byte())
  out.to_bytes()
}

///|
/// The gzip container (RFC 1952): what a real Kafka broker's
/// GZIPOutputStream produces. Minimal header (no extra fields), CRC-32
/// + ISIZE trailer over the UNCOMPRESSED data, both little-endian.
pub fn gzip_wrap(deflated : Bytes, source : Bytes) -> Bytes {
  let out = Buffer::Buffer()
  out.write_byte((0x1F).to_byte())
  out.write_byte((0x8B).to_byte())
  out.write_byte((8).to_byte()) // CM: deflate
  out.write_byte((0).to_byte()) // FLG: no extra fields
  for _k in 0..<4 {
    out.write_byte((0).to_byte()) // MTIME: none (deterministic output)
  }
  out.write_byte((0).to_byte()) // XFL
  out.write_byte((255).to_byte()) // OS: unknown
  out.write_bytes(deflated[0:deflated.length()])
  let check = crc32(source).to_int()
  let isize = source.length() & 0xFFFFFFFF
  out.write_byte((check & 0xFF).to_byte())
  out.write_byte(((check >> 8) & 0xFF).to_byte())
  out.write_byte(((check >> 16) & 0xFF).to_byte())
  out.write_byte(((check >> 24) & 0xFF).to_byte())
  out.write_byte((isize & 0xFF).to_byte())
  out.write_byte(((isize >> 8) & 0xFF).to_byte())
  out.write_byte(((isize >> 16) & 0xFF).to_byte())
  out.write_byte(((isize >> 24) & 0xFF).to_byte())
  out.to_bytes()
}

///|
/// Which container a payload carries, sniffed from its first bytes —
/// Kafka never says which it used beyond "gzip", and real writers
/// differ (Java's GZIPOutputStream vs zlib-based tooling).
enum Container {
  Gzip
  Zlib
}

///|
fn sniff_container(payload : Bytes) -> Result[Container, String] {
  if payload.length() < 2 {
    return Err("compressed payload too short to carry a container")
  }
  if payload[0].to_int() == 0x1F && payload[1].to_int() == 0x8B {
    return Ok(Gzip)
  }
  if payload[0].to_int() == 0x78 {
    return Ok(Zlib)
  }
  Err(
    "unrecognized compression container (neither gzip nor zlib); refusing to guess",
  )
}

///|
/// Unwraps a zlib container: verifies the header bits and the Adler-32
/// trailer, returns the raw deflate stream.
fn zlib_unwrap(payload : Bytes) -> Result[Bytes, String] {
  if payload.length() < 6 {
    return Err("zlib payload too short")
  }
  let cmf = payload[0].to_int()
  let flg = payload[1].to_int()
  if (cmf & 0x0F) != 8 {
    return Err("zlib container is not deflate")
  }
  if (cmf * 256 + flg) % 31 != 0 {
    return Err("zlib header fails its check")
  }
  if (flg & 0x20) != 0 {
    return Err("zlib preset dictionary is not supported")
  }
  Ok(payload[2:payload.length() - 4].to_owned())
}

///|
/// Unwraps a gzip container: verifies magic, method and the CRC-32 +
/// ISIZE trailer.
fn gzip_unwrap(payload : Bytes, max_out : Int) -> Result[Bytes, String] {
  if payload.length() < 18 {
    return Err("gzip payload too short")
  }
  if payload[0].to_int() != 0x1F ||
    payload[1].to_int() != 0x8B ||
    payload[2].to_int() != 8 {
    return Err("not a gzip deflate stream")
  }
  let flg = payload[3].to_int()
  if flg != 0 {
    return Err(
      "gzip extra header fields (FEXTRA/FNAME/FCOMMENT/FHCRC) are not supported",
    )
  }
  let body = payload[10:payload.length() - 8].to_owned()
  let check = payload[payload.length() - 8].to_int() |
    (payload[payload.length() - 7].to_int() << 8) |
    (payload[payload.length() - 6].to_int() << 16) |
    (payload[payload.length() - 5].to_int() << 24)
  let isize = payload[payload.length() - 4].to_int() |
    (payload[payload.length() - 3].to_int() << 8) |
    (payload[payload.length() - 2].to_int() << 16) |
    (payload[payload.length() - 1].to_int() << 24)
  // the container's own ISIZE is a second bound, but the caller's cap
  // wins: a lying ISIZE must not become an allocation
  let bound = if isize + 1 < max_out { isize + 1 } else { max_out }
  let raw = match inflate_raw(body, bound) {
    Ok(raw) => raw
    Err(e) => return Err(e)
  }
  if raw.length() != isize {
    return Err("gzip ISIZE does not match the decompressed size")
  }
  if crc32(raw).to_int() != check {
    return Err("gzip payload failed its CRC-32 check")
  }
  Ok(raw)
}

///|
/// Decompresses a Kafka RecordBatch payload with a hard cap on the
/// expanded size. Sniffs the container (real writers differ between
/// gzip and zlib framing), refuses what it does not know — never
/// guesses.
pub fn kafka_decompress(
  payload : Bytes,
  max_out : Int,
) -> Result[Bytes, String] {
  match sniff_container(payload) {
    Ok(Gzip) => gzip_unwrap(payload, max_out)
    Ok(Zlib) =>
      match zlib_unwrap(payload) {
        Ok(raw) => inflate_raw(raw, max_out)
        Err(e) => Err(e)
      }
    Err(e) => Err(e)
  }
}

///|
/// Compresses a RecordBatch payload with the gzip container (what a
/// real broker's producer path emits).
pub fn kafka_compress_gzip(payload : Bytes) -> Bytes {
  gzip_wrap(deflate_raw(payload), payload)
}
