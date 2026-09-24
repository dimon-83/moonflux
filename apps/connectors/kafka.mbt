// SPDX-License-Identifier: Apache-2.0
// Kafka connector (P20): the interoperability client.
//
// Kafka is an interoperability endpoint, not a reference system: this
// file speaks *Kafka's* wire protocol so a moonflux pipeline can sit
// beside real Kafka brokers, and it changes nothing about moonflux's
// own semantics (AGENTS §7 — a peer's assumptions are not our spec).
// It is hand-rolled for the same reason the MQTT client is: the
// dependency rule makes a protocol client the platform's own
// capability, and the record batch format is a documented binary
// structure, not a library feature.
//
// Pinned protocol versions (non-flexible encodings, no tagged fields).
// The layouts below were taken from the Kafka protocol definitions and
// cross-checked field by field against kafka-python 3.0.11 during
// development (a development-time reference only — not a dependency,
// not a gate):
//
//   ApiVersions v0 (key 18)   Metadata v1 (key 3)   ListOffsets v1 (key 2)
//   Produce v3 (key 0)        Fetch v4 (key 1)
//
// The client probes ApiVersions first and refuses a broker whose
// supported range excludes our versions: a clear error at connect beats
// a mis-parse at 3 a.m.
//
// Boundaries, written as boundaries rather than TODOs: no compression
// (a compressed batch that arrives is a structured error naming the
// codec), no consumer groups (direct partition assignment; the read
// offset lives in this process), no idempotence/transactions
// (producer_id = -1), no TLS/SASL, acks = 1, partition 0 unless the URL
// says otherwise.

///|
/// Where a kafka source starts reading. `Earliest`/`Latest` resolve
/// through ListOffsets (timestamp -2 / -1); `At` is an explicit offset.
pub(all) enum KafkaFrom {
  Earliest
  Latest
  At(Int64)
} derive(Debug, Eq, Show)

///|
/// A parsed `kafka://host:port/topic[?partition=N&from=earliest|latest|<offset>]`
/// URL. The topic is the URL's path; the bootstrap address is host:port
/// (default 9092).
pub(all) struct KafkaUrl {
  host : String
  port : Int
  topic : String
  partition : Int
  from : KafkaFrom
} derive(Debug)

///|
pub fn parse_kafka_url(url : String) -> Result[KafkaUrl, String] {
  if !url.has_prefix("kafka://") {
    return Err("url must start with kafka:// (the P20 client speaks plain TCP)")
  }
  // "kafka://" is eight characters: the mqtt parser's seven is a
  // different scheme, and copying it leaves a leading slash that makes
  // the authority empty
  let rest = url[8:url.length()].to_owned()
  let (authority_and_topic, query) = match rest.split_once("?") {
    Some((head, query)) => (head.to_owned(), query.to_owned())
    None => (rest, "")
  }
  let (authority, topic) = match authority_and_topic.split_once("/") {
    Some((authority, topic)) => (authority.to_owned(), topic.to_owned())
    None => return Err("kafka url needs a topic: kafka://host:port/topic")
  }
  if authority.length() == 0 || topic.length() == 0 {
    return Err(
      "kafka url needs both an authority and a topic: kafka://host:port/topic",
    )
  }
  let (host, port) = match authority.rev_split_once(":") {
    Some((host, port)) =>
      match (try? @string.parse_int(port.to_owned())) {
        Ok(port) =>
          if port <= 0 || port > 65535 {
            return Err("bad port in kafka url: \{port}")
          } else {
            (host.to_owned(), port)
          }
        Err(_) => return Err("bad port in kafka url")
      }
    None => (authority, 9092)
  }
  if host.length() == 0 {
    return Err("kafka url needs a host")
  }
  let mut partition = 0
  let mut from = Earliest
  if query.length() > 0 {
    for pair in query.split("&") {
      let pair = pair.to_owned()
      match pair.split_once("=") {
        Some((key, value)) =>
          match key.to_owned() {
            "partition" =>
              match (try? @string.parse_int(value.to_owned())) {
                Ok(n) =>
                  if n < 0 {
                    return Err("partition must not be negative in kafka url")
                  } else {
                    partition = n
                  }
                Err(_) => return Err("bad partition in kafka url: \{value}")
              }
            "from" =>
              match value.to_owned() {
                "earliest" => from = Earliest
                "latest" => from = Latest
                other =>
                  match (try? @string.parse_int(other)) {
                    Ok(n) =>
                      if n < 0 {
                        return Err("from offset must not be negative")
                      } else {
                        from = At(n.to_int64())
                      }
                    Err(_) =>
                      return Err(
                        "from must be earliest, latest, or an offset in kafka url",
                      )
                  }
              }
            other => return Err("unknown kafka url parameter: \{other}")
          }
        None => return Err("kafka url parameters look like key=value")
      }
    }
  }
  Ok(KafkaUrl::{ host, port, topic, partition, from })
}

// ---------------------------------------------------------------------------
// Wire primitives (Kafka's framing: big-endian, i16-prefixed strings,
// i32-counted arrays, i32-length-prefixed bytes)

///|
fn kw_i16(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value >> 8).to_byte())
  buf.write_byte((value & 0xFF).to_byte())
}

///|
fn kw_i32(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value >> 24).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte((value & 0xFF).to_byte())
}

///|
fn kw_i64(buf : Buffer, value : Int64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    buf.write_byte(((value >> shift) & 0xFFL).to_int().to_byte())
  }
}

///|
fn kw_u32(buf : Buffer, value : UInt) -> Unit {
  buf.write_byte((value >> 24).to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).to_int().to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).to_int().to_byte())
  buf.write_byte((value & 0xFFU).to_int().to_byte())
}

///|
fn kw_string(buf : Buffer, text : String) -> Unit {
  let bytes = @utf8.encode(text[0:text.length()])
  kw_i16(buf, bytes.length())
  buf.write_bytes(bytes)
}

///|
/// A nullable string: -1 on the wire for `None`.
fn kw_nullable_string(buf : Buffer, text : String?) -> Unit {
  match text {
    None => kw_i16(buf, -1)
    Some(text) => kw_string(buf, text)
  }
}

///|
fn kw_bytes(buf : Buffer, bytes : Bytes) -> Unit {
  kw_i32(buf, bytes.length())
  buf.write_bytes(bytes)
}

///|
/// Signed 16-bit read (sign-extends, so -1 arrives as -1).
fn kr_i16(reader : @codec.Reader) -> Result[Int, String] {
  match reader.read_u16_be() {
    Ok(v) => {
      let raw = v.to_int()
      Ok(if raw >= 0x8000 { raw - 0x10000 } else { raw })
    }
    Err(_) => Err("truncated i16")
  }
}

///|
fn kr_i32(reader : @codec.Reader) -> Result[Int, String] {
  match reader.read_u32_be() {
    Ok(v) => Ok(v.reinterpret_as_int())
    Err(_) => Err("truncated i32")
  }
}

///|
fn kr_i64(reader : @codec.Reader) -> Result[Int64, String] {
  match reader.read_i64_be() {
    Ok(v) => Ok(v)
    Err(_) => Err("truncated i64")
  }
}

///|
fn kr_u32(reader : @codec.Reader) -> Result[UInt, String] {
  match reader.read_u32_be() {
    Ok(v) => Ok(v)
    Err(_) => Err("truncated u32")
  }
}

///|
fn kr_string(reader : @codec.Reader) -> Result[String, String] {
  let len = match kr_i16(reader) {
    Ok(len) => len
    Err(e) => return Err(e)
  }
  if len < 0 {
    return Err("unexpected null string")
  }
  match reader.read_bytes(len) {
    Ok(bytes) => Ok(@utf8.decode_lossy(bytes[0:bytes.length()]))
    Err(_) => Err("truncated string")
  }
}

///|
/// A nullable string: -1 is `None`.
fn kr_nullable_string(reader : @codec.Reader) -> Result[String?, String] {
  let len = match kr_i16(reader) {
    Ok(len) => len
    Err(e) => return Err(e)
  }
  if len < 0 {
    return Ok(None)
  }
  match reader.read_bytes(len) {
    Ok(bytes) => Ok(Some(@utf8.decode_lossy(bytes[0:bytes.length()])))
    Err(_) => Err("truncated nullable string")
  }
}

///|
/// An i32-counted array: `None` for -1 (Kafka's null array), otherwise
/// the count — the caller reads that many elements.
fn kr_array_len(reader : @codec.Reader) -> Result[Int?, String] {
  let len = match kr_i32(reader) {
    Ok(len) => len
    Err(e) => return Err(e)
  }
  if len < 0 {
    return Ok(None)
  }
  // a count that cannot possibly fit in what remains is corruption,
  // not a big array: every element costs at least one byte
  if len > reader.remaining() + 1 {
    return Err(
      "array count \{len} exceeds the remaining \{reader.remaining()} bytes",
    )
  }
  Ok(Some(len))
}

///|
/// An i32-length-prefixed bytes field: -1 is the empty byte string
/// (Kafka uses null bytes for "no records" and readers treat it so).
fn kr_bytes_field(reader : @codec.Reader) -> Result[Bytes, String] {
  let len = match kr_i32(reader) {
    Ok(len) => len
    Err(e) => return Err(e)
  }
  if len < 0 {
    return Ok(b"")
  }
  match reader.read_bytes(len) {
    Ok(bytes) => Ok(bytes)
    Err(_) => Err("truncated bytes field")
  }
}

// ---------------------------------------------------------------------------
// Record-level varints (zigzag). Kafka's record fields use
// zigzag-encoded varints; the batch header's counts do not — exactly
// the kind of detail that makes a wire format feel personal.

///|
fn zigzag64(value : Int64) -> UInt64 {
  ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
}

///|
fn unzigzag64(value : UInt64) -> Int64 {
  let low = (value & 1UL).reinterpret_as_int64()
  (value >> 1).reinterpret_as_int64() ^ -low
}

///|
fn write_varint64(buf : Buffer, value : UInt64) -> Unit {
  let mut v = value
  while true {
    let mut digit = (v & 0x7FUL).to_int()
    v = v >> 7
    if v != 0UL {
      digit = digit | 0x80
    }
    buf.write_byte(digit.to_byte())
    if v == 0UL {
      break
    }
  }
}

///|
fn write_zigzag_varint(buf : Buffer, value : Int64) -> Unit {
  write_varint64(buf, zigzag64(value))
}

///|
fn read_zigzag_varint(reader : @codec.Reader) -> Result[Int64, String] {
  match reader.read_uleb128() {
    Ok(v) => Ok(unzigzag64(v))
    Err(_) => Err("truncated varint")
  }
}

// ---------------------------------------------------------------------------
// RecordBatch v2

///|
/// The batch header's fixed part, up to and including the record count.
/// Layout (big-endian): baseOffset i64, batchLength i32 (total minus
/// 12), partitionLeaderEpoch i32, magic u8 (= 2), crc u32, attributes
/// i16, lastOffsetDelta i32, firstTimestamp i64, maxTimestamp i64,
/// producerId i64, producerEpoch i16, baseSequence i32, recordCount i32.
///
/// **The CRC covers from `attributes` (offset 21) to the end** — the
/// base offset and the length are outside it, which is precisely how a
/// broker assigns an offset by rewriting eight bytes.
const BATCH_HEADER_BYTES : Int = 61

///|
/// Builds one uncompressed v2 batch from records. Offsets are deltas
/// 0..n-1 relative to the batch's base offset (the broker assigns the
/// base); timestamps are deltas relative to the first record's.
fn build_batch(records : Array[@protocol.Record], now_ms : Int64) -> Bytes {
  let base_ts = if records.length() > 0 { records[0].timestamp } else { now_ms }
  let mut max_ts = base_ts
  let records_bytes = Buffer::Buffer()
  for i, record in records {
    let body = Buffer::Buffer()
    body.write_byte(0) // record attributes: none
    write_zigzag_varint(body, record.timestamp - base_ts) // timestamp delta
    write_zigzag_varint(body, i.to_int64()) // offset delta
    if record.key.length() == 0 {
      write_zigzag_varint(body, -1L) // null key
    } else {
      write_zigzag_varint(body, record.key.length().to_int64())
      body.write_bytes(record.key)
    }
    write_zigzag_varint(body, record.value.length().to_int64())
    body.write_bytes(record.value)
    write_zigzag_varint(body, 0L) // no headers
    let record_bytes = body.to_bytes()
    write_zigzag_varint(records_bytes, record_bytes.length().to_int64())
    records_bytes.write_bytes(record_bytes)
    if record.timestamp > max_ts {
      max_ts = record.timestamp
    }
  }
  // the CRC-covered section: attributes .. end
  let covered = Buffer::Buffer()
  kw_i16(covered, 0) // attributes: no compression, create-time timestamps
  kw_i32(covered, records.length() - 1) // lastOffsetDelta
  kw_i64(covered, base_ts)
  kw_i64(covered, max_ts)
  kw_i64(covered, -1L) // producerId: not idempotent
  kw_i16(covered, -1) // producerEpoch
  kw_i32(covered, -1) // baseSequence
  kw_i32(covered, records.length())
  covered.write_bytes(records_bytes.to_bytes())
  let covered_bytes = covered.to_bytes()
  let crc = @codec.crc32c(covered_bytes)
  let batch = Buffer::Buffer()
  kw_i64(batch, 0L) // baseOffset: assigned by the broker
  kw_i32(batch, 9 + covered_bytes.length()) // batchLength = total - 12
  kw_i32(batch, -1) // partitionLeaderEpoch: unknown to a producer
  batch.write_byte(2) // magic: record batch v2
  kw_u32(batch, crc)
  batch.write_bytes(covered_bytes)
  batch.to_bytes()
}

///|
/// One decoded record, with its absolute Kafka offset.
priv struct KafkaRecord {
  offset : Int64
  record : @protocol.Record
}

///|
/// Parses a concatenation of v2 batches. Verifies every batch's CRC-32C
/// and refuses compressed batches by name — a silent misread of
/// compressed bytes would be worse than a refusal, and pretending to
/// decompress would be a lie.
fn parse_batches(
  bytes : Bytes,
  out : Array[KafkaRecord],
) -> Result[Unit, String] {
  let reader = @codec.Reader::new(bytes)
  while reader.remaining() > 0 {
    if reader.remaining() < BATCH_HEADER_BYTES {
      return Err("truncated batch header (\{reader.remaining()} bytes left)")
    }
    let base_offset = match kr_i64(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let batch_len = match kr_i32(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _leader_epoch = match kr_i32(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let magic = match reader.read_byte() {
      Ok(b) => b.to_int()
      Err(_) => return Err("truncated batch magic")
    }
    let crc = match kr_u32(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if magic != 2 {
      return Err(
        "unsupported record batch magic \{magic} (this client speaks v2)",
      )
    }
    let covered_len = batch_len - 9
    if covered_len < 0 || covered_len > reader.remaining() {
      return Err("batch length \{batch_len} does not fit the remaining bytes")
    }
    let covered = match reader.read_bytes(covered_len) {
      Ok(bytes) => bytes
      Err(_) => return Err("truncated batch body")
    }
    if @codec.crc32c(covered) != crc {
      return Err("batch at offset \{base_offset} failed its CRC-32C check")
    }
    let covered_reader = @codec.Reader::new(covered)
    let attributes = match kr_i16(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let codec = attributes & 0x07
    if codec != 0 {
      let name = match codec {
        1 => "gzip"
        2 => "snappy"
        3 => "lz4"
        4 => "zstd"
        _ => "unknown"
      }
      return Err(
        "compressed batches are not supported (codec \{name}); produce uncompressed or let the broker re-compress",
      )
    }
    let log_append_time = (attributes & 0x08) != 0
    let _last_offset_delta = match kr_i32(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let first_ts = match kr_i64(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let max_ts = match kr_i64(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _producer_id = match kr_i64(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _producer_epoch = match kr_i16(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _base_sequence = match kr_i32(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let count = match kr_i32(covered_reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if count < 0 {
      return Err("negative record count in batch")
    }
    for _i in 0..<count {
      let record_len = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if record_len < 0 || record_len.to_int() > covered_reader.remaining() {
        return Err("record length does not fit its batch")
      }
      let record_end = covered_reader.position() + record_len.to_int()
      let _attributes = match covered_reader.read_byte() {
        Ok(b) => b
        Err(_) => return Err("truncated record attributes")
      }
      let ts_delta = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let offset_delta = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let key_len = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let key = if key_len < 0 {
        b""
      } else {
        match covered_reader.read_bytes(key_len.to_int()) {
          Ok(bytes) => bytes
          Err(_) => return Err("truncated record key")
        }
      }
      let value_len = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let value = if value_len < 0 {
        b""
      } else {
        match covered_reader.read_bytes(value_len.to_int()) {
          Ok(bytes) => bytes
          Err(_) => return Err("truncated record value")
        }
      }
      let header_count = match read_zigzag_varint(covered_reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      for _h in 0..<header_count.to_int() {
        let h_key_len = match read_zigzag_varint(covered_reader) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if h_key_len > 0L {
          let _ = covered_reader.read_bytes(h_key_len.to_int())
        }
        let h_value_len = match read_zigzag_varint(covered_reader) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if h_value_len > 0L {
          let _ = covered_reader.read_bytes(h_value_len.to_int())
        }
      }
      // the record's own length is authoritative: seek to its end
      // rather than trusting this field list — a parser that trusts
      // its own list over the wire's count drifts the moment the
      // format grows
      let overshoot = covered_reader.position() - record_end
      if overshoot > 0 {
        return Err("record parsed \{overshoot} bytes past its own length")
      }
      if overshoot < 0 {
        let _ = covered_reader.read_bytes(-overshoot)
      }
      out.push(KafkaRecord::{
        offset: base_offset + offset_delta,
        record: @protocol.Record::{
          // log-append-time batches carry the broker's clock in
          // maxTimestamp and no per-record delta worth trusting
          timestamp: if log_append_time {
            max_ts
          } else {
            first_ts + ts_delta
          },
          key,
          value,
          headers: [],
        },
      })
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// The session

///|
/// One broker session. Kafka is request/response with a correlation id
/// per request; the connection is kept across calls (a session per
/// request would pay a metadata round trip per batch).
priv struct KafkaConn {
  mut stream : @net.TcpStream?
  mut correlation : Int
}

///|
/// One request/response round: header (api key, version, correlation,
/// client id), body, then the framed answer (i32 size, i32
/// correlation, body). The correlation must echo — a mismatched answer
/// is a protocol violation, not something to paper over.
fn kafka_request(
  conn : KafkaConn,
  stream : @net.TcpStream,
  api_key : Int,
  api_version : Int,
  body : Bytes,
) -> Result[Bytes, String] {
  conn.correlation += 1
  let correlation = conn.correlation
  let out = Buffer::Buffer()
  kw_i16(out, api_key)
  kw_i16(out, api_version)
  kw_i32(out, correlation)
  kw_string(out, "moonflux-kafka")
  out.write_bytes(body)
  // requests are size-prefixed exactly like responses: without it the
  // broker reads the api key as a length and waits for four million
  // more bytes (the gate caught this as a connect-time hang)
  let payload = out.to_bytes()
  let framed = Buffer::Buffer()
  kw_i32(framed, payload.length())
  framed.write_bytes(payload)
  match stream.send_all(framed.to_bytes()) {
    Ok(_) => ()
    Err(e) => return Err("send: \{e}")
  }
  let head = match read_exact_stream(stream, 4) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let size = (head[0].to_int() << 24) |
    (head[1].to_int() << 16) |
    (head[2].to_int() << 8) |
    head[3].to_int()
  if size < 4 || size > 64 * 1024 * 1024 {
    return Err("implausible response size \{size}")
  }
  let frame = match read_exact_stream(stream, size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let echo = (frame[0].to_int() << 24) |
    (frame[1].to_int() << 16) |
    (frame[2].to_int() << 8) |
    frame[3].to_int()
  if echo != correlation {
    return Err(
      "correlation mismatch: sent \{correlation}, got \{echo} (the session is out of step)",
    )
  }
  Ok(frame[4:size].to_owned())
}

///|
/// Reads exactly `n` bytes from a stream; a timeout is an error here —
/// every caller has already decided what "nothing" means at its own
/// level (fetch quietness is an *empty response*, not a silent socket).
fn read_exact_stream(stream : @net.TcpStream, n : Int) -> Result[Bytes, String] {
  let out = Buffer::Buffer()
  let chunk : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut need = n
  while need > 0 {
    match stream.recv(chunk, need) {
      Ok(0) => return Err("broker closed mid-response")
      Ok(got) => {
        out.write_bytes(Bytes::from_fixedarray(chunk, len=got)[0:got])
        need -= got
      }
      Err(e) => return Err("recv: \{e}")
    }
  }
  Ok(out.to_bytes())
}

///|
/// Opens a session to `host:port`: TCP, then the ApiVersions probe,
/// then the version assertion. The probe exists so a broker that only
/// speaks newer (or much older) protocol versions fails here, with its
/// own advertised range in the message, instead of failing later as a
/// mis-parse.
fn kafka_connect(
  host : String,
  port : Int,
  conn : KafkaConn,
) -> Result[@net.TcpStream, String] {
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{host}:\{port}: \{e}")
  }
  // fetches wait server-side (max_wait_ms); the socket deadline is the
  // client's backstop against a broker that answers nothing at all
  match stream.set_recv_timeout_ms(6000) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("set read deadline: \{e}")
    }
  }
  let versions = match kafka_api_versions(conn, stream) {
    Ok(versions) => versions
    Err(e) => {
      let _ = stream.close()
      return Err(e)
    }
  }
  for
    requirement in [
      (0, 3, 3, "Produce v3"),
      (1, 4, 4, "Fetch v4"),
      (2, 1, 1, "ListOffsets v1"),
      (3, 1, 1, "Metadata v1"),
      (18, 0, 0, "ApiVersions v0"),
    ] {
    let (key, min, max, label) = requirement
    match versions.get(key) {
      Some(range) =>
        if range.0 > max || range.1 < min {
          let _ = stream.close()
          return Err(
            "broker does not support \{label} (advertises v\{range.0}..v\{range.1}); this client pins non-flexible versions",
          )
        }
      None => {
        let _ = stream.close()
        return Err("broker does not advertise \{label}")
      }
    }
  }
  Ok(stream)
}

///|
/// ApiVersions v0: an empty body; the answer maps api key → (min, max).
fn kafka_api_versions(
  conn : KafkaConn,
  stream : @net.TcpStream,
) -> Result[Map[Int, (Int, Int)], String] {
  let body = match kafka_request(conn, stream, 18, 0, b"") {
    Ok(body) => body
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(body)
  let error = match kr_i16(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if error != 0 {
    return Err("ApiVersions failed with error code \{error}")
  }
  let count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("ApiVersions returned a null array")
    Err(e) => return Err(e)
  }
  let out : Map[Int, (Int, Int)] = {}
  for _i in 0..<count {
    let key = match kr_i16(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let min = match kr_i16(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let max = match kr_i16(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out[key] = (min, max)
  }
  Ok(out)
}

///|
/// The host:port a topic partition's leader lives on (Metadata v1).
fn kafka_leader(
  conn : KafkaConn,
  stream : @net.TcpStream,
  topic : String,
  partition : Int,
) -> Result[String, String] {
  let body = Buffer::Buffer()
  kw_i32(body, 1) // topics array: exactly one
  kw_string(body, topic)
  let answer = match kafka_request(conn, stream, 3, 1, body.to_bytes()) {
    Ok(answer) => answer
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(answer)
  let broker_count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("metadata brokers: null array")
    Err(e) => return Err(e)
  }
  let brokers : Map[Int, String] = {}
  for _i in 0..<broker_count {
    let node_id = match kr_i32(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let host = match kr_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let port = match kr_i32(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _rack = match kr_nullable_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    brokers[node_id] = "\{host}:\{port}"
  }
  let _controller_id = match kr_i32(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let topic_count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("metadata topics: null array")
    Err(e) => return Err(e)
  }
  if topic_count == 0 {
    return Err("broker has no metadata for topic \{topic}")
  }
  let mut leader = ""
  for _t in 0..<topic_count {
    let topic_error = match kr_i16(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let name = match kr_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let _is_internal = match reader.read_byte() {
      Ok(b) => b
      Err(_) => return Err("truncated is_internal")
    }
    if topic_error != 0 {
      return Err("metadata for \{name}: broker error code \{topic_error}")
    }
    let part_count = match kr_array_len(reader) {
      Ok(Some(count)) => count
      Ok(None) => return Err("metadata partitions: null array")
      Err(e) => return Err(e)
    }
    let mut saw_partition = false
    for _p in 0..<part_count {
      let part_error = match kr_i16(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let index = match kr_i32(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let leader_id = match kr_i32(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let replicas = match kr_array_len(reader) {
        Ok(Some(count)) => count
        Ok(None) => return Err("replicas: null array")
        Err(e) => return Err(e)
      }
      for _r in 0..<replicas {
        let _ = kr_i32(reader)
      }
      let isr = match kr_array_len(reader) {
        Ok(Some(count)) => count
        Ok(None) => return Err("isr: null array")
        Err(e) => return Err(e)
      }
      for _r in 0..<isr {
        let _ = kr_i32(reader)
      }
      if name == topic && index == partition {
        saw_partition = true
        if part_error != 0 {
          return Err(
            "partition \{partition} of \{topic}: broker error code \{part_error}",
          )
        }
        match brokers.get(leader_id) {
          Some(addr) => leader = addr
          None =>
            return Err("metadata names leader \{leader_id} but no such broker")
        }
      }
    }
    if name == topic && !saw_partition {
      return Err(
        "topic \{topic} has no partition \{partition} (the broker's metadata lists \{part_count})",
      )
    }
  }
  if leader == "" {
    return Err("no leader found for \{topic}[\{partition}]")
  }
  Ok(leader)
}

///|
/// ListOffsets v1: timestamp -2 = earliest, -1 = latest.
fn kafka_resolve_offset(
  conn : KafkaConn,
  stream : @net.TcpStream,
  topic : String,
  partition : Int,
  timestamp : Int64,
) -> Result[Int64, String] {
  let body = Buffer::Buffer()
  kw_i32(body, -1) // replica_id: a consumer
  kw_i32(body, 1) // topics array: exactly one
  kw_string(body, topic)
  kw_i32(body, 1) // partitions array: exactly one
  kw_i32(body, partition)
  kw_i64(body, timestamp)
  let answer = match kafka_request(conn, stream, 2, 1, body.to_bytes()) {
    Ok(answer) => answer
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(answer)
  let topic_count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("list_offsets topics: null array")
    Err(e) => return Err(e)
  }
  for _t in 0..<topic_count {
    let _name = match kr_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let part_count = match kr_array_len(reader) {
      Ok(Some(count)) => count
      Ok(None) => return Err("list_offsets partitions: null array")
      Err(e) => return Err(e)
    }
    for _p in 0..<part_count {
      let _index = match kr_i32(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let error = match kr_i16(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let _ts = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let offset = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if error != 0 {
        return Err("ListOffsets: broker error code \{error}")
      }
      return Ok(offset)
    }
  }
  Err("ListOffsets answered nothing for \{topic}[\{partition}]")
}

///|
/// Produce v3: one partition, one batch, acks=1.
fn kafka_produce(
  conn : KafkaConn,
  stream : @net.TcpStream,
  topic : String,
  partition : Int,
  batch : Bytes,
) -> Result[Int64, String] {
  let body = Buffer::Buffer()
  kw_nullable_string(body, None) // transactional_id
  kw_i16(body, 1) // acks: the leader writes, we wait for its word
  kw_i32(body, 10000) // timeout_ms
  kw_i32(body, 1) // topic_data: exactly one
  kw_string(body, topic)
  kw_i32(body, 1) // partition_data: exactly one
  kw_i32(body, partition)
  kw_bytes(body, batch)
  let answer = match kafka_request(conn, stream, 0, 3, body.to_bytes()) {
    Ok(answer) => answer
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(answer)
  let topic_count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("produce responses: null array")
    Err(e) => return Err(e)
  }
  for _t in 0..<topic_count {
    let _name = match kr_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let part_count = match kr_array_len(reader) {
      Ok(Some(count)) => count
      Ok(None) => return Err("produce partitions: null array")
      Err(e) => return Err(e)
    }
    for _p in 0..<part_count {
      let _index = match kr_i32(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let error = match kr_i16(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let base_offset = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let _log_append_time = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if error != 0 {
        return Err("produce: broker error code \{error}")
      }
      return Ok(base_offset)
    }
  }
  let _throttle = match kr_i32(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Err("produce answered nothing for \{topic}[\{partition}]")
}

///|
/// Fetch v4: one partition, wait up to 300 ms for at least one byte —
/// an empty answer after the wait is the caller's "quiet", returned as
/// an empty record list rather than a socket timeout.
fn kafka_fetch(
  conn : KafkaConn,
  stream : @net.TcpStream,
  topic : String,
  partition : Int,
  fetch_offset : Int64,
) -> Result[Array[KafkaRecord], String] {
  let body = Buffer::Buffer()
  kw_i32(body, -1) // replica_id: a consumer
  kw_i32(body, 300) // max_wait_ms
  kw_i32(body, 1) // min_bytes: answer as soon as there is anything
  kw_i32(body, 4 * 1024 * 1024) // max_bytes
  body.write_byte(0) // isolation_level: read_uncommitted
  kw_i32(body, 1) // topics array: exactly one
  kw_string(body, topic)
  kw_i32(body, 1) // partitions array: exactly one
  kw_i32(body, partition)
  kw_i64(body, fetch_offset)
  kw_i32(body, 4 * 1024 * 1024) // partition_max_bytes
  let answer = match kafka_request(conn, stream, 1, 4, body.to_bytes()) {
    Ok(answer) => answer
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(answer)
  let _throttle = match kr_i32(reader) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let topic_count = match kr_array_len(reader) {
    Ok(Some(count)) => count
    Ok(None) => return Err("fetch responses: null array")
    Err(e) => return Err(e)
  }
  let records : Array[KafkaRecord] = []
  for _t in 0..<topic_count {
    let _name = match kr_string(reader) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let part_count = match kr_array_len(reader) {
      Ok(Some(count)) => count
      Ok(None) => return Err("fetch partitions: null array")
      Err(e) => return Err(e)
    }
    for _p in 0..<part_count {
      let _index = match kr_i32(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let error = match kr_i16(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let _high_watermark = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let _last_stable_offset = match kr_i64(reader) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      // aborted_transactions: a nullable array of (producer_id, first_offset)
      match kr_array_len(reader) {
        Ok(Some(count)) =>
          for _a in 0..<count {
            let _producer = kr_i64(reader)
            let _first = kr_i64(reader)
          }
        Ok(None) => ()
        Err(e) => return Err(e)
      }
      let bytes = match kr_bytes_field(reader) {
        Ok(bytes) => bytes
        Err(e) => return Err(e)
      }
      if error != 0 {
        return Err("fetch: broker error code \{error}")
      }
      match parse_batches(bytes, records) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  Ok(records)
}

// ---------------------------------------------------------------------------
// The connector pair

///|
/// A session that resolves the leader once and keeps the connection. A
/// failed operation drops the session so the next attempt re-resolves
/// metadata — the Kafka way to survive a leader moving is to ask
/// again, not to guess.
priv struct KafkaSession {
  conn : KafkaConn
}

///|
/// Opens a session against the bootstrap broker and converges on the
/// leader for `topic[partition]` (the same broker, in the common case).
fn kafka_open_session(
  target : KafkaUrl,
) -> Result[(KafkaSession, @net.TcpStream), String] {
  let conn = KafkaConn::{ stream: None, correlation: 0 }
  let bootstrap = match kafka_connect(target.host, target.port, conn) {
    Ok(stream) => stream
    Err(e) => return Err(e)
  }
  let leader = match
    kafka_leader(conn, bootstrap, target.topic, target.partition) {
    Ok(leader) => leader
    Err(e) => {
      let _ = bootstrap.close()
      return Err(e)
    }
  }
  let want = "\{target.host}:\{target.port}"
  if leader != want {
    let (host, port) = match leader.rev_split_once(":") {
      Some((host, port)) =>
        match (try? @string.parse_int(port.to_owned())) {
          Ok(port) => (host.to_owned(), port)
          Err(_) => (leader, 9092)
        }
      None => (leader, 9092)
    }
    let _ = bootstrap.close()
    let stream = match kafka_connect(host, port, conn) {
      Ok(stream) => stream
      Err(e) => return Err(e)
    }
    return Ok((KafkaSession::{ conn, }, stream))
  }
  Ok((KafkaSession::{ conn, }, bootstrap))
}

///|
/// The sink's session state: the connection plus the socket it owns.
/// A `None` stream means the next flush opens (or re-opens) everything.
priv struct KafkaSinkState {
  mut session : KafkaSession?
  mut stream : @net.TcpStream?
}

///|
fn open_sink_stream(
  state : KafkaSinkState,
  target : KafkaUrl,
) -> Result[@net.TcpStream, String] {
  let (session, stream) = match kafka_open_session(target) {
    Ok(parts) => parts
    Err(e) => return Err(e)
  }
  state.session = Some(session)
  state.stream = Some(stream)
  Ok(stream)
}

///|
/// Kafka sink: publish each batch's records in one v2 record batch to
/// the URL's topic partition, acks=1. Record keys and timestamps are
/// preserved; partition 0 unless the URL says otherwise.
pub fn kafka_sink(url : String) -> Sink {
  let parsed = parse_kafka_url(url)
  let state : KafkaSinkState = KafkaSinkState::{ session: None, stream: None }
  Sink::{
    name: "kafka-produce:\{url}",
    flush: fn(records) {
      let target = match parsed {
        Ok(target) => target
        Err(e) => return Err(e)
      }
      if records.length() == 0 {
        return Ok(())
      }
      let stream = match state.stream {
        Some(stream) => stream
        None =>
          match open_sink_stream(state, target) {
            Ok(stream) => stream
            Err(e) => return Err(e)
          }
      }
      let conn = match state.session {
        Some(session) => session.conn
        None => return Err("kafka session lost")
      }
      let batch = build_batch(records, @env.now().reinterpret_as_int64())
      match kafka_produce(conn, stream, target.topic, target.partition, batch) {
        Ok(_) => Ok(())
        Err(e) => {
          // drop the session: the next flush re-resolves metadata
          let _ = stream.close()
          state.session = None
          state.stream = None
          Err(e)
        }
      }
    },
  }
}

///|
/// A source's session, with the read position the broker never asked
/// about (no consumer group: the offset is this process's memory, and
/// a restart re-applies the URL's `from`).
priv struct KafkaSourceState {
  mut session : KafkaSession?
  mut stream : @net.TcpStream?
  mut next_offset : Int64
  mut resolved : Bool
}

///|
/// Kafka source: resolve the start offset once (`from`), then each pull
/// fetches one window. Records keep their Kafka offsets, keys, and
/// timestamps; an empty response after the broker's own wait is
/// `Quiet`.
pub fn kafka_source(url : String) -> Source {
  let parsed = parse_kafka_url(url)
  let state : KafkaSourceState = KafkaSourceState::{
    session: None,
    stream: None,
    next_offset: 0L,
    resolved: false,
  }
  Source::{
    name: "kafka:\{url}",
    pull: fn() {
      let target = match parsed {
        Ok(target) => target
        Err(e) => return Err(e)
      }
      let stream = match state.stream {
        Some(stream) => stream
        None => {
          let (session, stream) = match kafka_open_session(target) {
            Ok(parts) => parts
            Err(e) => return Err(e)
          }
          state.session = Some(session)
          state.stream = Some(stream)
          state.resolved = false
          stream
        }
      }
      let conn = match state.session {
        Some(s) => s.conn
        None => return Err("kafka session lost")
      }
      if !state.resolved {
        match target.from {
          At(offset) => state.next_offset = offset
          Earliest | Latest => {
            let timestamp = if target.from is Earliest { -2L } else { -1L }
            match
              kafka_resolve_offset(
                conn,
                stream,
                target.topic,
                target.partition,
                timestamp,
              ) {
              Ok(offset) => state.next_offset = offset
              Err(e) => {
                let _ = stream.close()
                state.session = None
                state.stream = None
                return Err(e)
              }
            }
          }
        }
        state.resolved = true
      }
      let records = match
        kafka_fetch(
          conn,
          stream,
          target.topic,
          target.partition,
          state.next_offset,
        ) {
        Ok(records) => records
        Err(e) => {
          let _ = stream.close()
          state.session = None
          state.stream = None
          state.resolved = false
          return Err(e)
        }
      }
      if records.length() == 0 {
        return Ok(Quiet)
      }
      let out : Array[@protocol.Record] = []
      let mut highest = state.next_offset
      for entry in records {
        out.push(entry.record)
        if entry.offset >= highest {
          highest = entry.offset + 1L
        }
      }
      state.next_offset = highest
      Ok(Records(out))
    },
  }
}
