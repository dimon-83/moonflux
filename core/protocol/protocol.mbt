// SPDX-License-Identifier: Apache-2.0
// core/protocol: moonflux wire protocol v1 — Record and RecordBatch
// framing. Pure computation only (kernel red lines, AGENTS §5).
//
// Frame layout v1 (all integers big-endian):
//   0   3  magic "MFB"
//   3   1  version = 0x01
//   4   4  batch_length: bytes after this field (frame total = 8 + batch_length)
//   8   8  base_offset: i64, -1 = unassigned (producer path). EXCLUDED from CRC
//          so a broker can assign offsets without re-reading the payload.
//  16   4  crc32: over record_count..records_len + records blob
//  20   4  record_count: u32
//  24   4  records_len: u32 (byte length of the records blob)
//  28   N  records blob
//
// Record (inside the blob):
//   uleb128 total_len (bytes after this field)
//   i64    timestamp_ms
//   uleb128 key_len + key bytes (0 = empty; v1 has no distinct null)
//   uleb128 value_len + value bytes
//   uleb128 headers_count, then per header: uleb128 klen + bytes, uleb128 vlen + bytes
//
// Segment files are concatenations of frames: a log file IS a valid
// protocol byte stream. Limits below are checked before allocation.

///|
/// Upper bound for one batch frame, including all headers (16 MiB).
pub const MAX_BATCH_BYTES = 16777216

///|
/// Upper bound for a single record inside the blob (4 MiB).
pub const MAX_RECORD_BYTES = 4194304

///|
/// Upper bound for records in one batch.
pub const MAX_RECORDS_PER_BATCH = 100000

///|
/// Upper bound for headers on one record.
pub const MAX_HEADERS_PER_RECORD = 1024

///|
/// Wire protocol failure modes. Closed set: every malformed input
/// maps onto exactly one case (kernel red line: no panics on
/// untrusted bytes).
pub(all) suberror ProtocolError {
  /// Fewer bytes than a fixed header (or a frame body) remain.
  Incomplete
  /// Frame does not start with the "MFB" magic.
  BadMagic
  /// Magic matches but the version byte is not 0x01.
  UnsupportedVersion(Int)
  /// Stored CRC-32 does not match the computed one.
  CrcMismatch
  /// Length fields are mutually inconsistent or the blob did not
  /// decompose into exactly `record_count` records.
  MalformedLength
  /// A varint exceeded its 10-byte width bound.
  InvalidVarint
  /// A length or count exceeds the protocol limits.
  ValueTooLarge
} derive(Debug, Eq)

///|
pub impl Show for ProtocolError with fn output(self, logger) {
  let s = match self {
    Incomplete => "Incomplete"
    BadMagic => "BadMagic"
    UnsupportedVersion(v) => "UnsupportedVersion(\{v})"
    CrcMismatch => "CrcMismatch"
    MalformedLength => "MalformedLength"
    InvalidVarint => "InvalidVarint"
    ValueTooLarge => "ValueTooLarge"
  }
  logger.write_string(s)
}

///|
/// One log/wire record. `timestamp` is milliseconds since the epoch
/// as supplied by an injected Clock; empty `Bytes` fields denote
/// absent values (v1 has no distinct null).
pub(all) struct Record {
  timestamp : Int64
  key : Bytes
  value : Bytes
  headers : Array[(Bytes, Bytes)]
} derive(Debug, Eq, Show)

///|
/// A decoded batch frame: the broker-assigned base offset plus the
/// records it carries.
pub(all) struct DecodedBatch {
  base_offset : Int64
  records : Array[Record]
} derive(Debug, Eq, Show)

///|
fn write_len_bytes(buf : @buffer.Buffer, data : Bytes) -> Unit {
  buf.write_leb128(data.length())
  buf.write_bytes(data[0:data.length()])
}

///|
fn encode_record_into(r : Record, buf : @buffer.Buffer) -> Unit {
  let body = @buffer.Buffer::Buffer()
  body.write_int64_be(r.timestamp)
  write_len_bytes(body, r.key)
  write_len_bytes(body, r.value)
  body.write_leb128(r.headers.length())
  for h in r.headers {
    write_len_bytes(body, h.0)
    write_len_bytes(body, h.1)
  }
  buf.write_leb128(body.length())
  buf.write_bytes(body.to_bytes()[0:body.length()])
}

///|
/// Encodes one frame carrying `records` with the given base offset.
/// `records` may be empty. Deterministic: same input, same bytes.
pub fn encode_frame(base_offset : Int64, records : Array[Record]) -> Bytes {
  let blob = @buffer.Buffer::Buffer()
  for r in records {
    encode_record_into(r, blob)
  }
  let crc_input = @buffer.Buffer::Buffer()
  crc_input.write_uint_be(records.length().reinterpret_as_uint())
  crc_input.write_uint_be(blob.length().reinterpret_as_uint())
  crc_input.write_bytes(blob.to_bytes()[0:blob.length()])
  let crc = @codec.crc32(crc_input.to_bytes())
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MFB"[0:3])
  out.write_byte(b'\x01')
  let batch_length = 20 + blob.length()
  out.write_uint_be(batch_length.reinterpret_as_uint())
  out.write_int64_be(base_offset)
  out.write_uint_be(crc)
  out.write_bytes(crc_input.to_bytes()[0:crc_input.length()])
  out.to_bytes()
}

///|
/// The bytes one frame costs regardless of its records: magic +
/// version (4) + batch_length (4) + the fixed body before the blob
/// (base offset 8 + crc 4 + count 4 + blob length 4). Public because
/// a caller that budgets a *frame* (a reader capping a window, a
/// producer sizing a chunk) has to include it, and a second copy of
/// "28" is a second answer waiting to disagree.
pub const FRAME_OVERHEAD_BYTES : Int = 28

///|
/// How many bytes `value` needs as a LEB128 varint (the length prefix
/// `encode_record_into` writes in front of each record body).
fn uleb128_size(value : Int) -> Int {
  let mut remaining = value
  let mut size = 1
  while remaining >= 128 {
    remaining = remaining >> 7
    size += 1
  }
  size
}

///|
/// The encoded size of one record inside a batch blob — its length
/// prefix included. This is the accounting a producer needs to keep a
/// frame inside a budget *before* it encodes it: the limits in this
/// file are checked by the decoder, and a producer that only learns
/// them from a rejection has already put an unshippable frame on the
/// wire (P15).
pub fn record_wire_size(record : Record) -> Int {
  let body = @buffer.Buffer::Buffer()
  body.write_int64_be(record.timestamp)
  write_len_bytes(body, record.key)
  write_len_bytes(body, record.value)
  body.write_leb128(record.headers.length())
  for h in record.headers {
    write_len_bytes(body, h.0)
    write_len_bytes(body, h.1)
  }
  let body_len = body.length()
  uleb128_size(body_len) + body_len
}

///|
/// The frame `encode_frame` would produce for `records`, in bytes —
/// the *whole* frame, so a caller can compare it against
/// `MAX_BATCH_BYTES` (which bounds `batch_length`, i.e. everything
/// after the length field) without doing the arithmetic twice.
pub fn batch_wire_size(records : Array[Record]) -> Int {
  let mut total = FRAME_OVERHEAD_BYTES
  for record in records {
    total += record_wire_size(record)
  }
  total
}

///|
/// How many leading records fit in one frame of at most `max_bytes`.
///
/// Two rules, both deliberate:
/// - at least one record is returned for a non-empty input, however
///   large it is: refusing to *carry* the first record would turn a
///   producer's oversize payload into a stall that never reports why,
///   and the decoder's own `ValueTooLarge` is the honest refusal;
/// - `max_bytes <= 0` means "no budget": every record fits, which is
///   what callers that are not sizing a wire frame (tests, whole-log
///   tooling) mean.
pub fn batch_fit(records : Array[Record], max_bytes : Int) -> Int {
  if records.length() == 0 {
    return 0
  }
  let mut bytes = FRAME_OVERHEAD_BYTES
  let mut taken = 0
  for record in records {
    let size = record_wire_size(record)
    if taken > 0 && max_bytes > 0 && bytes + size > max_bytes {
      break
    }
    bytes += size
    taken += 1
  }
  taken
}

///|
/// Splits records into consecutive batches, each within `max_bytes`
/// of encoded frame. Order is preserved, so batch k's offsets are
/// contiguous with batch k+1's and a producer can report one range
/// for the whole send.
///
/// An empty input yields one empty batch, not zero: `produce` of
/// nothing still has to answer with the log's end, and a caller that
/// was handed a consequence-free request should not have to special
/// case it.
pub fn split_batches(
  records : Array[Record],
  max_bytes : Int,
) -> Array[Array[Record]] {
  if records.length() == 0 {
    return [records]
  }
  let out : Array[Array[Record]] = []
  let mut start = 0
  while start < records.length() {
    let take = batch_fit(records[start:records.length()].to_owned(), max_bytes)
    out.push(records[start:start + take].to_owned())
    start += take
  }
  out
}

///|
/// Why one record cannot travel on the wire, or `None` when it can.
/// The per-field bound is the decoder's (`read_len_bytes` refuses a
/// key or value over `MAX_RECORD_BYTES`); checking it here means a
/// producer says "this record is too big, and here is which part" in
/// the caller's own process instead of a round trip that ends in
/// `ValueTooLarge`.
pub fn record_size_violation(record : Record) -> String? {
  if record.key.length() > MAX_RECORD_BYTES {
    return Some(
      "key of \{record.key.length()} bytes exceeds the \{MAX_RECORD_BYTES}-byte per-field limit",
    )
  }
  if record.value.length() > MAX_RECORD_BYTES {
    return Some(
      "value of \{record.value.length()} bytes exceeds the \{MAX_RECORD_BYTES}-byte per-field limit",
    )
  }
  None
}

///|
fn read_len_bytes(reader : @codec.Reader) -> Result[Bytes, ProtocolError] {
  let len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(other) => return Err(map_decode_error(other))
  }
  if len > MAX_RECORD_BYTES {
    return Err(ValueTooLarge)
  }
  match reader.read_bytes(len) {
    Ok(data) => Ok(data)
    Err(UnexpectedEof) => Err(Incomplete)
    Err(other) => Err(map_decode_error(other))
  }
}

///|
fn map_decode_error(e : @codec.DecodeError) -> ProtocolError {
  match e {
    UnexpectedEof => Incomplete
    VarintTooLong => InvalidVarint
    LengthOutOfRange => ValueTooLarge
    InvalidHex => MalformedLength // unreachable from byte decoding
  }
}

///|
fn decode_record(reader : @codec.Reader) -> Result[Record, ProtocolError] {
  let total_len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(other) => return Err(map_decode_error(other))
  }
  if total_len > MAX_RECORD_BYTES {
    return Err(ValueTooLarge)
  }
  let body = match reader.read_bytes(total_len) {
    Ok(body) => body
    Err(UnexpectedEof) => return Err(Incomplete)
    Err(other) => return Err(map_decode_error(other))
  }
  let br = @codec.Reader::new(body)
  let timestamp = match br.read_i64_be() {
    Ok(ts) => ts
    Err(_) => return Err(Incomplete)
  }
  let key = match read_len_bytes(br) {
    Ok(data) => data
    Err(e) => return Err(e)
  }
  let value = match read_len_bytes(br) {
    Ok(data) => data
    Err(e) => return Err(e)
  }
  let header_count = match br.read_uleb128_len() {
    Ok(count) => count
    Err(other) => return Err(map_decode_error(other))
  }
  if header_count > MAX_HEADERS_PER_RECORD {
    return Err(ValueTooLarge)
  }
  let headers : Array[(Bytes, Bytes)] = []
  for _i in 0..<header_count {
    let k = match read_len_bytes(br) {
      Ok(data) => data
      Err(e) => return Err(e)
    }
    let v = match read_len_bytes(br) {
      Ok(data) => data
      Err(e) => return Err(e)
    }
    headers.push((k, v))
  }
  if br.remaining() != 0 {
    return Err(MalformedLength)
  }
  Ok(Record::{ timestamp, key, value, headers, })
}

///|
/// Decodes exactly one frame from the reader, consuming its bytes.
/// A short input maps to `Incomplete` — the log recovery path treats
/// a trailing `Incomplete` as a torn tail and truncates there.
pub fn decode_frame(
  reader : @codec.Reader,
) -> Result[DecodedBatch, ProtocolError] {
  if reader.remaining() < 28 {
    return Err(Incomplete)
  }
  let head = match reader.read_bytes(4) {
    Ok(head) => head
    Err(_) => return Err(Incomplete)
  }
  if head[0] != b'M' || head[1] != b'F' || head[2] != b'B' {
    return Err(BadMagic)
  }
  let version = head[3].to_int()
  if version != 1 {
    return Err(UnsupportedVersion(version))
  }
  let batch_length = match reader.read_u32_be() {
    Ok(len) => len.reinterpret_as_int()
    Err(_) => return Err(Incomplete)
  }
  if batch_length < 20 {
    return Err(MalformedLength)
  }
  if batch_length > MAX_BATCH_BYTES {
    return Err(ValueTooLarge)
  }
  let body = match reader.read_bytes(batch_length) {
    Ok(body) => body
    Err(UnexpectedEof) => return Err(Incomplete)
    Err(other) => return Err(map_decode_error(other))
  }
  let br = @codec.Reader::new(body)
  let base_offset = match br.read_i64_be() {
    Ok(offset) => offset
    Err(_) => return Err(Incomplete)
  }
  let stored_crc = match br.read_u32_be() {
    Ok(crc) => crc
    Err(_) => return Err(Incomplete)
  }
  let count = match br.read_u32_be() {
    Ok(count) => count.reinterpret_as_int()
    Err(_) => return Err(Incomplete)
  }
  let records_len = match br.read_u32_be() {
    Ok(len) => len.reinterpret_as_int()
    Err(_) => return Err(Incomplete)
  }
  if records_len != br.remaining() {
    return Err(MalformedLength)
  }
  if count > MAX_RECORDS_PER_BATCH {
    return Err(ValueTooLarge)
  }
  // CRC covers count + records_len + records blob, i.e. everything
  // in the body after base_offset and the stored crc field.
  let crc_actual = @codec.crc32_view(body[12:body.length()])
  if crc_actual != stored_crc {
    return Err(CrcMismatch)
  }
  let records : Array[Record] = []
  for _i in 0..<count {
    match decode_record(br) {
      Ok(record) => records.push(record)
      Err(e) => return Err(e)
    }
  }
  if br.remaining() != 0 {
    return Err(MalformedLength)
  }
  Ok(DecodedBatch::{ base_offset, records, })
}

///|
/// Decodes one frame spanning the whole input; trailing bytes that
/// do not belong to the frame are rejected. Convenience for
/// single-frame payloads (tests, fixtures, session frames).
pub fn decode_frame_strict(
  bytes : Bytes,
) -> Result[DecodedBatch, ProtocolError] {
  let reader = @codec.Reader::new(bytes)
  match decode_frame(reader) {
    Ok(batch) =>
      if reader.remaining() != 0 {
        Err(MalformedLength)
      } else {
        Ok(batch)
      }
    Err(e) => Err(e)
  }
}
