// core/log: single-partition commit log over an injected segment
// handle. Pure computation (kernel red lines, AGENTS §5): the host
// supplies IO through `SegmentFile` function fields; the kernel owns
// offset assignment, framing, and crash-recovery semantics.
//
// P0 scope: one segment per partition. Segment indexes and multi-
// segment rolling arrive with the P3 storage milestone; reads scan
// frames from the segment start (documented limitation).

///|

///|
/// Host-reported failure or log-semantic violation.
pub(all) suberror LogError {
  /// The injected storage reported an IO failure.
  Storage(String)
  /// A frame in the middle of the segment failed integrity checks
  /// (CRC mismatch, bad magic, malformed lengths). Recovery refuses
  /// to guess past silent corruption.
  CorruptFrame
  /// `read` started at an offset that was never written.
  OffsetOutOfRange
  /// The encoded batch exceeds the protocol batch limit.
  BatchTooLarge
} derive(Debug, Eq)

///|
pub impl Show for LogError with fn output(self, logger) {
  match self {
    Storage(msg) => logger.write_string("Storage(\{msg})")
    CorruptFrame => logger.write_string("CorruptFrame")
    OffsetOutOfRange => logger.write_string("OffsetOutOfRange")
    BatchTooLarge => logger.write_string("BatchTooLarge")
  }
}

///|
/// Host-injected handle for one segment file. Function fields keep
/// the kernel IO-free while letting the native adapter supply real
/// files and tests supply memory.
pub(all) struct SegmentFile {
  /// Reads `length` bytes at absolute `position`.
  read : (Int, Int) -> Result[Bytes, LogError]
  /// Appends bytes; returns the new total size.
  append : (Bytes) -> Result[Int, LogError]
  /// Current file size in bytes.
  size : () -> Result[Int, LogError]
  /// Durably persists appended bytes (may be a no-op for memory).
  flush : () -> Result[Unit, LogError]
  /// Cuts the file to `new_size` bytes (crash recovery truncates
  /// torn tails).
  truncate : (Int) -> Result[Unit, LogError]
} derive(Debug)

///|
/// In-memory segment for tests and WASM backends.
pub struct MemorySegment {
  data : @buffer.Buffer
}

///|
pub fn MemorySegment::new() -> MemorySegment {
  MemorySegment::{ data: @buffer.Buffer::Buffer() }
}

///|
/// The bytes written so far (test/debug observation).
pub fn MemorySegment::contents(self : MemorySegment) -> Bytes {
  self.data.to_bytes()
}

///|
/// A `SegmentFile` handle backed by this memory buffer.
pub fn MemorySegment::handle(self : MemorySegment) -> SegmentFile {
  SegmentFile::{
    read: fn(position, length) {
      let total = self.data.length()
      if position < 0 || length < 0 || position + length > total {
        return Err(Storage("read out of bounds"))
      }
      Ok(self.data.to_bytes()[position:position + length].to_owned())
    },
    append: fn(bytes) {
      self.data.write_bytes(bytes[0:bytes.length()])
      Ok(self.data.length())
    },
    size: fn() { Ok(self.data.length()) },
    flush: fn() { Ok(()) },
    truncate: fn(new_size) {
      if new_size > self.data.length() {
        return Err(Storage("truncate beyond size"))
      }
      let kept = self.data.to_bytes()[0:new_size].to_owned()
      self.data.reset()
      self.data.write_bytes(kept[0:kept.length()])
      Ok(())
    },
  }
}

///|
/// One log entry as returned by `read`: the assigned offset plus the
/// record stored under it.
pub(all) struct LogEntry {
  offset : Int64
  record : @protocol.Record
} derive(Debug, Eq, Show)

///|
/// Commit log over one segment: assigns offsets, frames batches with
/// the wire protocol, and recovers a consistent prefix on open.
pub struct SegmentedLog {
  file : SegmentFile
  mut valid_size : Int
  mut next_offset : Int64
} derive(Debug)

///|
/// Opens (or recovers) the log backed by `file`. The valid prefix of
/// the segment is kept; a torn tail (trailing partial frame) is
/// truncated away, matching crash semantics: an append either fully
/// survived or is entirely lost.
pub fn SegmentedLog::open(file : SegmentFile) -> Result[SegmentedLog, LogError] {
  let size = match (file.size)() {
    Ok(size) => size
    Err(e) => return Err(e)
  }
  let bytes = match (file.read)(0, size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(bytes)
  let mut consumed = 0
  let mut next_offset : Int64 = 0L
  let mut torn_tail = false
  while reader.remaining() > 0 {
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        next_offset += batch.records.length().to_int64()
        consumed = size - reader.remaining()
      }
      Err(Incomplete) => {
        torn_tail = true
        break
      }
      Err(_) => return Err(CorruptFrame)
    }
  }
  if torn_tail && consumed < size {
    match (file.truncate)(consumed) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(SegmentedLog::{ file, valid_size: consumed, next_offset })
}

///|
/// The exclusive upper bound of assigned offsets: the offset the
/// next appended record will receive.
pub fn SegmentedLog::high_watermark(self : SegmentedLog) -> Int64 {
  self.next_offset
}

///|
/// Appends one batch; every record receives a consecutive offset.
/// Returns the offset assigned to the first record. Appending zero
/// records writes nothing and returns the next offset unchanged.
pub fn SegmentedLog::append(
  self : SegmentedLog,
  records : Array[@protocol.Record],
) -> Result[Int64, LogError] {
  if records.length() == 0 {
    return Ok(self.next_offset)
  }
  if records.length() > @protocol.MAX_RECORDS_PER_BATCH {
    return Err(BatchTooLarge)
  }
  let frame = @protocol.encode_frame(self.next_offset, records)
  if frame.length() > @protocol.MAX_BATCH_BYTES {
    return Err(BatchTooLarge)
  }
  match (self.file.append)(frame) {
    Ok(new_size) => {
      self.valid_size = new_size
      let base = self.next_offset
      self.next_offset += records.length().to_int64()
      match (self.file.flush)() {
        Ok(_) => Ok(base)
        Err(e) => Err(e)
      }
    }
    Err(e) => Err(e)
  }
}

///|
/// Reads at most `max_records` entries starting at absolute offset
/// `from`. Returns them in offset order, each carrying its assigned
/// offset. P0 implementation scans frames from the segment start
/// (no index yet).
pub fn SegmentedLog::read(
  self : SegmentedLog,
  from : Int64,
  max_records : Int,
) -> Result[Array[LogEntry], LogError] {
  if from < 0L || from > self.next_offset || max_records < 0 {
    return Err(OffsetOutOfRange)
  }
  if from == self.next_offset || max_records == 0 {
    return Ok([])
  }
  let bytes = match (self.file.read)(0, self.valid_size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(bytes)
  let out : Array[LogEntry] = []
  let mut next = 0L
  while reader.remaining() > 0 && out.length() < max_records {
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        let count = batch.records.length()
        let batch_end = next + count.to_int64()
        if batch_end > from {
          // `from` lands inside (or before) this batch: skip records
          // before it (never negative — earlier batches may already
          // have covered `from`), then take what remains.
          let raw_skip = (from - next).to_int()
          let skip = if raw_skip < 0 { 0 } else { raw_skip }
          let mut i = skip
          while i < count && out.length() < max_records {
            out.push(LogEntry::{
              offset: next + i.to_int64(),
              record: batch.records[i],
            })
            i += 1
          }
        }
        next = batch_end
      }
      Err(_) => return Err(CorruptFrame)
    }
  }
  Ok(out)
}
