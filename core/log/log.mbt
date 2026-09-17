// SPDX-License-Identifier: Apache-2.0
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
/// One stored segment, as the host reports it. `created_ms` is the
/// host's wall clock at creation: the kernel compares it against a
/// `now` the caller supplies, because the kernel never reads a clock
/// itself (AGENTS §5).
pub(all) struct SegmentInfo {
  base : Int64
  size : Int
  created_ms : Int64
} derive(Debug, Eq, Show)

///|
/// Host-injected storage for one partition's segments. The kernel owns
/// *what* a segment means (frames, offsets, boundaries); the host owns
/// where the bytes live. Listing is the source of truth for what
/// exists: a store that cannot list its segments cannot be recovered.
pub(all) struct SegmentStore {
  /// Opens (creating if needed) the segment whose first record is
  /// `base`.
  open_segment : (Int64) -> Result[SegmentFile, LogError]
  /// Every existing segment, in any order (the kernel sorts).
  list : () -> Result[Array[SegmentInfo], LogError]
  /// Opens (creating if needed) the *index* file of a segment. The
  /// index is an accelerator, never truth: a missing or unreadable one
  /// costs a scan, and the kernel rebuilds it.
  open_index : (Int64) -> Result[SegmentFile, LogError]
  /// Removes a whole segment **and its index**. Only retention and
  /// truncation call this, and only for segments the kernel has
  /// decided to drop.
  remove : (Int64) -> Result[Unit, LogError]
} derive(Debug)

///|
/// A memory-backed store: tests and non-IO backends. Segments are
/// created on demand, and the creation stamp is settable so age-based
/// policy can be exercised without a clock.
pub struct MemorySegmentStore {
  bases : Array[Int64]
  segments : Array[MemorySegment]
  indexes : Array[MemorySegment]
  created : Array[Int64]
}

///|
pub fn MemorySegmentStore::new() -> MemorySegmentStore {
  MemorySegmentStore::{ bases: [], segments: [], indexes: [], created: [] }
}

///|
/// The handle the kernel talks to.
pub fn MemorySegmentStore::store(self : MemorySegmentStore) -> SegmentStore {
  SegmentStore::{
    open_segment: fn(base) {
      match self.index_of(base) {
        Some(i) => Ok(self.segments[i].handle())
        None => {
          self.bases.push(base)
          self.segments.push(MemorySegment::new())
          self.indexes.push(MemorySegment::new())
          self.created.push(0L)
          Ok(self.segments[self.segments.length() - 1].handle())
        }
      }
    },
    open_index: fn(base) {
      match self.index_of(base) {
        Some(i) => Ok(self.indexes[i].handle())
        None => {
          self.bases.push(base)
          self.segments.push(MemorySegment::new())
          self.indexes.push(MemorySegment::new())
          self.created.push(0L)
          Ok(self.indexes[self.indexes.length() - 1].handle())
        }
      }
    },
    list: fn() {
      let out : Array[SegmentInfo] = []
      for i, base in self.bases {
        out.push(SegmentInfo::{
          base,
          size: self.segments[i].contents().length(),
          created_ms: self.created[i],
        })
      }
      Ok(out)
    },
    remove: fn(base) {
      match self.index_of(base) {
        Some(i) => {
          let _ = self.bases.remove(i)
          let _ = self.segments.remove(i)
          let _ = self.indexes.remove(i)
          let _ = self.created.remove(i)
          Ok(())
        }
        None => Err(Storage("no such segment \{base}"))
      }
    },
  }
}

///|
fn MemorySegmentStore::index_of(
  self : MemorySegmentStore,
  base : Int64,
) -> Int? {
  for i, existing in self.bases {
    if existing == base {
      return Some(i)
    }
  }
  None
}

///|
/// The segment bases this store holds, ascending (test observation).
pub fn MemorySegmentStore::bases(self : MemorySegmentStore) -> Array[Int64] {
  let out = self.bases.copy()
  out.sort()
  out
}

///|
/// The bytes of one segment (test observation).
pub fn MemorySegmentStore::contents(
  self : MemorySegmentStore,
  base : Int64,
) -> Bytes {
  match self.index_of(base) {
    Some(i) => self.segments[i].contents()
    None => b""
  }
}

///|
/// The bytes of one segment's index (test observation).
pub fn MemorySegmentStore::index_contents(
  self : MemorySegmentStore,
  base : Int64,
) -> Bytes {
  match self.index_of(base) {
    Some(i) => self.indexes[i].contents()
    None => b""
  }
}

///|
/// Sets a segment's creation stamp (age-policy tests).
pub fn MemorySegmentStore::set_created_ms(
  self : MemorySegmentStore,
  base : Int64,
  created_ms : Int64,
) -> Unit {
  match self.index_of(base) {
    Some(i) => self.created[i] = created_ms
    None => ()
  }
}

///|
/// One segment as an operator sees it: which offsets it covers and how
/// many bytes it costs.
pub(all) struct SegmentSummary {
  base : Int64
  records : Int64
  bytes : Int
} derive(Debug, Eq, Show)

///|
/// One log entry as returned by `read`: the assigned offset plus the
/// record stored under it.
pub(all) struct LogEntry {
  offset : Int64
  record : @protocol.Record
} derive(Debug, Eq, Show)

///|
/// Why recovery cut bytes off the segment end.
pub(all) enum RecoveryReason {
  /// Every byte decoded as complete frames.
  Clean
  /// The last frame ran past the end of the file (crash mid-append).
  TornTail
  /// A frame failed integrity checks; everything from it on was
  /// discarded (crash-recovery semantics: ignore torn/corrupt
  /// batches, expose the confirmed watermark).
  CorruptFrame
} derive(Debug, Eq, Show)

///|
/// Outcome of the recovery scan performed by `open`.
pub(all) struct RecoveryReport {
  reason : RecoveryReason
  /// Bytes kept: the end of the last complete, valid frame.
  valid_size : Int
  /// Bytes removed from the tail by recovery.
  discarded_bytes : Int
} derive(Debug, Eq, Show)

///|
/// One sparse index anchor: the offset of the record that starts at
/// byte `position` within its segment. Anchors always sit on frame
/// boundaries, which is what lets a reader start there without
/// resynchronising.
pub(all) struct IndexAnchor {
  offset : Int64
  position : Int
} derive(Debug, Eq, Show)

///|
/// Every Nth record (and at least every M bytes) becomes an anchor.
/// The two bounds together keep both the index small and the scan
/// short; the values are policy, so they are configuration, not
/// constants of the format.
const DEFAULT_INDEX_EVERY_RECORDS : Int = 64

///|
const INDEX_EVERY_BYTES : Int = 4096

///|
/// The index file format, version 1:
///   `MFI1` | segment base (8, big endian) | count (4, big endian) |
///   (offset 8 BE, position 4 BE) × count | crc32 (4 BE)
/// The CRC covers everything before it, so a plausible-looking but
/// damaged index is *detected* rather than trusted — the fallback is a
/// scan, and a scan is always right.
const INDEX_MAGIC : Bytes = b"MFI1"

///|
fn encode_index(base : Int64, anchors : Array[IndexAnchor]) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_bytes(INDEX_MAGIC[0:4])
  buf.write_int64_be(base)
  buf.write_uint_be(anchors.length().reinterpret_as_uint())
  for anchor in anchors {
    buf.write_int64_be(anchor.offset)
    buf.write_uint_be(anchor.position.reinterpret_as_uint())
  }
  let body = buf.to_bytes()
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(body[0:body.length()])
  out.write_uint_be(@codec.crc32(body))
  out.to_bytes()
}

///|
/// Decodes and validates an index. Every failure mode returns None:
/// the caller's answer to "the index is not usable" is a scan, so
/// being strict here costs nothing and being lenient would risk
/// answering from a stale index.
fn decode_index(
  bytes : Bytes,
  base : Int64,
  segment_size : Int,
) -> Array[IndexAnchor]? {
  if bytes.length() < 20 {
    return None
  }
  if bytes[0:4].to_owned() != INDEX_MAGIC {
    return None
  }
  let count = ((bytes[12].to_uint() << 24) |
  (bytes[13].to_uint() << 16) |
  (bytes[14].to_uint() << 8) |
  bytes[15].to_uint()).to_int()
  if count <= 0 || count > 1000000 {
    return None
  }
  let expected = 16 + count * 12 + 4
  if bytes.length() != expected {
    return None
  }
  let body = bytes[0:expected - 4].to_owned()
  let stored_crc = (bytes[expected - 4].to_uint() << 24) |
    (bytes[expected - 3].to_uint() << 16) |
    (bytes[expected - 2].to_uint() << 8) |
    bytes[expected - 1].to_uint()
  if @codec.crc32(body) != stored_crc {
    return None
  }
  let stored_base = read_i64_be(bytes, 4)
  if stored_base != base {
    return None
  }
  let anchors : Array[IndexAnchor] = []
  let mut previous_offset = -1L
  let mut previous_position = -1
  for i = 0; i < count; i = i + 1 {
    let at = 16 + i * 12
    let offset = read_i64_be(bytes, at)
    let position = ((bytes[at + 8].to_uint() << 24) |
    (bytes[at + 9].to_uint() << 16) |
    (bytes[at + 10].to_uint() << 8) |
    bytes[at + 11].to_uint()).to_int()
    // anchors must describe a walk forward through this segment
    if offset <= previous_offset || position <= previous_position {
      return None
    }
    if position >= segment_size {
      return None
    }
    anchors.push(IndexAnchor::{ offset, position })
    previous_offset = offset
    previous_position = position
  }
  if anchors[0].offset != base || anchors[0].position < 0 {
    return None
  }
  Some(anchors)
}

///|
fn read_i64_be(bytes : Bytes, at : Int) -> Int64 {
  let mut value : Int64 = 0L
  for i = 0; i < 8; i = i + 1 {
    value = (value << 8) | bytes[at + i].to_int64()
  }
  value
}

///|
/// A commit log over a **sequence of segments**: assigns offsets,
/// frames batches with the wire protocol, rolls to a new segment when
/// the active one reaches `roll_bytes` (0 = never), and recovers a
/// consistent prefix on open.
///
/// The invariants that make segmentation invisible to every reader:
/// a segment boundary is always a *frame* boundary, bases are strictly
/// increasing with no holes (appends only ever go to the active
/// segment, so a hole cannot arise — one that exists is reported, not
/// repaired), and only the last segment can carry a torn tail.
pub struct SegmentedLog {
  store : SegmentStore
  /// ascending by base; the last one is active
  segments : Array[LogSegment]
  mut next_offset : Int64
  recovery : RecoveryReport
  /// 0 disables rolling (the pre-P8 single-segment behavior)
  roll_bytes : Int
  /// how many records may pass between index anchors (size bounds the
  /// scan, record count bounds the index)
  index_every_records : Int
} derive(Debug)

///|
/// One open segment: the file, its byte size, and when it was created
/// (the store's stamp, for age-based policy).
struct LogSegment {
  base : Int64
  file : SegmentFile
  mut size : Int
  created_ms : Int64
  /// sparse anchors, ascending; [0] is always (base, 0)
  mut anchors : Array[IndexAnchor]
  /// whether the on-disk index matches `anchors`
  mut index_saved : Bool
} derive(Debug)

///|
/// Opens the log over a single file — the pre-P8 shape, kept because
/// it is exactly a one-segment store with rolling disabled, and every
/// existing caller and test means that.
pub fn SegmentedLog::open(file : SegmentFile) -> Result[SegmentedLog, LogError] {
  let size = match (file.size)() {
    Ok(size) => size
    Err(e) => return Err(e)
  }
  let store = SegmentStore::{
    open_segment: fn(base) {
      if base == 0L {
        Ok(file)
      } else {
        Err(Storage("this store holds a single segment"))
      }
    },
    list: fn() { Ok([SegmentInfo::{ base: 0L, size, created_ms: 0L }]) },
    open_index: fn(_base) { Err(Storage("this store holds a single segment")) },
    remove: fn(_base) { Err(Storage("this store holds a single segment")) },
  }
  SegmentedLog::open_store(store, 0)
}

///|
/// Opens (or recovers) the log held by `store`. Only the **last**
/// segment is scanned: it is the only one that can carry a torn or
/// corrupt tail, because appends go nowhere else and a roll happens
/// after a successful flush. Trailing *empty* segments are dropped —
/// that is the crash-during-roll case, and an empty segment is not a
/// segment.
pub fn SegmentedLog::open_store(
  store : SegmentStore,
  roll_bytes : Int,
) -> Result[SegmentedLog, LogError] {
  SegmentedLog::open_store_configured(
    store,
    roll_bytes,
    DEFAULT_INDEX_EVERY_RECORDS,
  )
}

///|
/// `open_store` with the anchor interval spelled out. One anchor every
/// `index_every_records` records (and at least every INDEX_EVERY_BYTES
/// bytes) is the trade the index makes; tests drive it small so a few
/// records produce several anchors.
pub fn SegmentedLog::open_store_configured(
  store : SegmentStore,
  roll_bytes : Int,
  index_every_records : Int,
) -> Result[SegmentedLog, LogError] {
  if roll_bytes < 0 {
    return Err(Storage("roll_bytes must not be negative"))
  }
  if index_every_records <= 0 {
    return Err(Storage("index_every_records must be positive"))
  }
  let infos_raw = match (store.list)() {
    Ok(infos) => infos
    Err(e) => return Err(e)
  }
  let infos = infos_raw.copy()
  infos.sort_by(fn(a, b) {
    if a.base < b.base {
      -1
    } else if a.base > b.base {
      1
    } else {
      0
    }
  })
  // no segments yet: a fresh log starts at offset 0
  if infos.length() == 0 {
    let file = match (store.open_segment)(0L) {
      Ok(file) => file
      Err(e) => return Err(e)
    }
    return Ok(SegmentedLog::{
      store,
      segments: [
        LogSegment::{
          base: 0L,
          file,
          size: 0,
          created_ms: 0L,
          anchors: [IndexAnchor::{ offset: 0L, position: 0 }],
          index_saved: true,
        },
      ],
      next_offset: 0L,
      recovery: RecoveryReport::{
        reason: Clean,
        valid_size: 0,
        discarded_bytes: 0,
      },
      roll_bytes,
      index_every_records: DEFAULT_INDEX_EVERY_RECORDS,
    })
  }
  // the bases must be strictly increasing: a hole or a repeat means the
  // store is not describing one log, and guessing would silently break
  // the offset contract every reader depends on
  for i = 1; i < infos.length(); i = i + 1 {
    if infos[i].base <= infos[i - 1].base {
      return Err(
        Storage(
          "segment bases must increase strictly: \{infos[i - 1].base} then \{infos[i].base}",
        ),
      )
    }
  }
  let segments : Array[LogSegment] = []
  for info in infos {
    let file = match (store.open_segment)(info.base) {
      Ok(file) => file
      Err(e) => return Err(e)
    }
    let size = match (file.size)() {
      Ok(size) => size
      Err(e) => return Err(e)
    }
    segments.push(LogSegment::{
      base: info.base,
      file,
      size,
      created_ms: info.created_ms,
      anchors: [],
      index_saved: false,
    })
  }
  // drop empty trailing segments (crash between create and first append)
  while segments.length() > 1 && segments[segments.length() - 1].size == 0 {
    let last = segments[segments.length() - 1]
    match (store.remove)(last.base) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let kept : Array[LogSegment] = []
    for i = 0; i < segments.length() - 1; i = i + 1 {
      kept.push(segments[i])
    }
    segments.clear()
    for seg in kept {
      segments.push(seg)
    }
  }
  // an empty segment in the *middle* is a hole: appends only ever go to
  // the active segment, so an empty non-trailing segment means the
  // store is not describing one continuous log — refuse rather than
  // pretend the offsets line up
  if segments.length() > 1 {
    for i = 0; i < segments.length() - 1; i = i + 1 {
      if segments[i].size == 0 {
        return Err(
          Storage(
            "segment \{segments[i].base} is empty but not the last: the log has a hole",
          ),
        )
      }
    }
  }
  // every segment gets anchors: from its stored index when that is
  // present and consistent, by scanning when it is not. The last
  // segment is scanned for recovery anyway, so its rebuild is free.
  for i = 0; i < segments.length(); i = i + 1 {
    let seg = segments[i]
    let loaded = if i + 1 < segments.length() {
      self_index_or_none(store, seg)
    } else {
      None
    }
    match loaded {
      Some(anchors) => {
        seg.anchors = anchors
        seg.index_saved = true
      }
      None =>
        // rebuilt below, once the last segment's size is known: for
        // sealed segments the size is already final
        if i + 1 < segments.length() {
          match rebuild_index_static(seg, index_every_records) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
    }
  }
  // recover the last segment: a torn or corrupt tail is cut there, and
  // the record count of every earlier segment is implied by the base
  // chain (their bytes were flushed whole when they were sealed)
  let last = segments[segments.length() - 1]
  let size = last.size
  let bytes = match (last.file.read)(0, size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(bytes)
  let mut consumed = 0
  let mut records : Int64 = 0L
  let mut reason = Clean
  while reader.remaining() > 0 {
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        records += batch.records.length().to_int64()
        consumed = size - reader.remaining()
      }
      Err(Incomplete) => {
        reason = TornTail
        break
      }
      Err(_) => {
        reason = CorruptFrame
        break
      }
    }
  }
  if consumed < size {
    match (last.file.truncate)(consumed) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  last.size = consumed
  let recovery = RecoveryReport::{
    reason,
    valid_size: consumed,
    discarded_bytes: size - consumed,
  }
  // the last segment was just scanned, so its anchors are known: write
  // them out (best effort) and reuse that scan instead of a second one
  match rebuild_index_static(last, index_every_records) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok(SegmentedLog::{
    store,
    segments,
    next_offset: last.base + records,
    recovery,
    roll_bytes,
    index_every_records: DEFAULT_INDEX_EVERY_RECORDS,
  })
}

///|
/// The exclusive upper bound of assigned offsets: the offset the
/// next appended record will receive.
pub fn SegmentedLog::high_watermark(self : SegmentedLog) -> Int64 {
  self.next_offset
}

///|
/// The oldest offset still stored. Zero until retention deletes
/// anything; afterwards it is the base of the oldest surviving
/// segment, and reads below it are refused rather than quietly empty.
pub fn SegmentedLog::first_offset(self : SegmentedLog) -> Int64 {
  if self.segments.length() == 0 {
    return 0L
  }
  self.segments[0].base
}

///|
/// The segments as an operator sees them, ascending.
pub fn SegmentedLog::segment_summaries(
  self : SegmentedLog,
) -> Array[SegmentSummary] {
  let out : Array[SegmentSummary] = []
  for i, seg in self.segments {
    let next_base = if i + 1 < self.segments.length() {
      self.segments[i + 1].base
    } else {
      self.next_offset
    }
    out.push(SegmentSummary::{
      base: seg.base,
      records: next_base - seg.base,
      bytes: seg.size,
    })
  }
  out
}

///|
/// The active segment: the last one, which is where appends land.
fn SegmentedLog::active(self : SegmentedLog) -> LogSegment {
  self.segments[self.segments.length() - 1]
}

///|
/// The index of the segment that contains `offset` (the last segment
/// whose base is at or below it), or None when the offset is below the
/// oldest surviving segment.
fn SegmentedLog::segment_index_for(self : SegmentedLog, offset : Int64) -> Int? {
  let mut found : Int? = None
  for i, seg in self.segments {
    if seg.base <= offset {
      found = Some(i)
    }
  }
  found
}

///|
/// Rolls to a fresh segment when the active one has reached the
/// threshold. Rolling happens **after** a successful append, so a
/// boundary is always a frame boundary and a crash here leaves an
/// empty segment that `open_store` drops.
fn SegmentedLog::maybe_roll(self : SegmentedLog) -> Result[Unit, LogError] {
  if self.roll_bytes <= 0 {
    return Ok(())
  }
  if self.active().size < self.roll_bytes {
    return Ok(())
  }
  // sealing is the moment an index is worth writing: the segment will
  // not change again, so what lands on disk stays true
  self.save_index(self.active())
  let file = match (self.store.open_segment)(self.next_offset) {
    Ok(file) => file
    Err(e) => return Err(e)
  }
  self.segments.push(LogSegment::{
    base: self.next_offset,
    file,
    size: 0,
    created_ms: 0L,
    anchors: [IndexAnchor::{ offset: self.next_offset, position: 0 }],
    index_saved: true,
  })
  Ok(())
}

///|
/// The stored index for a segment, or None when it is absent, stale or
/// unreadable. Used during open, where no SegmentedLog exists yet.
fn self_index_or_none(
  store : SegmentStore,
  seg : LogSegment,
) -> Array[IndexAnchor]? {
  let file = match (store.open_index)(seg.base) {
    Ok(file) => file
    Err(_) => return None
  }
  let size = match (file.size)() {
    Ok(size) => size
    Err(_) => return None
  }
  if size == 0 {
    return None
  }
  let bytes = match (file.read)(0, size) {
    Ok(bytes) => bytes
    Err(_) => return None
  }
  decode_index(bytes, seg.base, seg.size)
}

///|
/// Scans a segment and rebuilds its anchors in place (the form open
/// uses, before the log object exists).
fn rebuild_index_static(
  seg : LogSegment,
  index_every_records : Int,
) -> Result[Unit, LogError] {
  let anchors : Array[IndexAnchor] = [
    IndexAnchor::{ offset: seg.base, position: 0 },
  ]
  if seg.size > 0 {
    let bytes = match (seg.file.read)(0, seg.size) {
      Ok(bytes) => bytes
      Err(e) => return Err(e)
    }
    let reader = @codec.Reader::new(bytes)
    let mut next = seg.base
    let mut take = 0
    while reader.remaining() > 0 {
      let before = reader.position()
      match @protocol.decode_frame(reader) {
        Ok(batch) => {
          let count = batch.records.length()
          if take >= index_every_records && before > 0 {
            anchors.push(IndexAnchor::{ offset: next, position: before })
            take = 0
          }
          next += count.to_int64()
          take += count
        }
        Err(_) => return Err(CorruptFrame)
      }
    }
  }
  seg.anchors = anchors
  seg.index_saved = false
  Ok(())
}

///|
/// The stored index for a segment, or None when it is absent, stale or
/// unreadable. Validation lives in `decode_index`; this only fetches.
fn SegmentedLog::load_index(
  self : SegmentedLog,
  seg : LogSegment,
) -> Array[IndexAnchor]? {
  let file = match (self.store.open_index)(seg.base) {
    Ok(file) => file
    Err(_) => return None
  }
  let size = match (file.size)() {
    Ok(size) => size
    Err(_) => return None
  }
  if size == 0 {
    return None
  }
  let bytes = match (file.read)(0, size) {
    Ok(bytes) => bytes
    Err(_) => return None
  }
  decode_index(bytes, seg.base, seg.size)
}

///|
/// Writes the segment's anchors out. Best effort by design: the index
/// is an accelerator, and failing to persist one must never fail an
/// append or an open — the next reader just scans.
fn SegmentedLog::save_index(self : SegmentedLog, seg : LogSegment) -> Unit {
  if seg.index_saved {
    return
  }
  let file = match (self.store.open_index)(seg.base) {
    Ok(file) => file
    Err(_) => return
  }
  let bytes = encode_index(seg.base, seg.anchors)
  match (file.truncate)(0) {
    Ok(_) => ()
    Err(_) => return
  }
  match (file.append)(bytes) {
    Ok(_) => ()
    Err(_) => return
  }
  match (file.flush)() {
    Ok(_) => ()
    Err(_) => return
  }
  seg.index_saved = true
}

///|
/// Rebuilds a segment's anchors by scanning it. This is the fallback
/// the whole design leans on: any doubt about the stored index is
/// answered by reading the segment, which is always right.
fn SegmentedLog::rebuild_index(
  self : SegmentedLog,
  seg : LogSegment,
) -> Result[Unit, LogError] {
  let anchors : Array[IndexAnchor] = [
    IndexAnchor::{ offset: seg.base, position: 0 },
  ]
  let bytes = match (seg.file.read)(0, seg.size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(bytes)
  let mut next = seg.base
  let mut take = 0
  while reader.remaining() > 0 {
    let before = reader.position()
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        let count = batch.records.length()
        if take >= self.index_every_records && before > 0 {
          anchors.push(IndexAnchor::{ offset: next, position: before })
          take = 0
        }
        next += count.to_int64()
        take += count
      }
      Err(_) => return Err(CorruptFrame)
    }
  }
  seg.anchors = anchors
  seg.index_saved = false
  Ok(())
}

///|
/// The anchor to start reading `from` at: the last anchor at or before
/// it. Never returns None for a segment that exists (anchor [0] is the
/// segment base), so readers cannot end up anchorless.
fn anchor_for(seg : LogSegment, from : Int64) -> IndexAnchor {
  let mut best = IndexAnchor::{ offset: seg.base, position: 0 }
  for anchor in seg.anchors {
    if anchor.offset <= from {
      best = anchor
    }
  }
  best
}

///|
/// Records an anchor for the frame about to be written, when the
/// previous one has drifted far enough. Called *before* the append, so
/// the anchor points at a frame boundary by construction.
fn SegmentedLog::maybe_anchor(self : SegmentedLog) -> Unit {
  let seg = self.active()
  if seg.anchors.length() == 0 {
    seg.anchors.push(IndexAnchor::{ offset: seg.base, position: 0 })
  }
  let last = seg.anchors[seg.anchors.length() - 1]
  if seg.size - last.position >= INDEX_EVERY_BYTES {
    seg.anchors.push(IndexAnchor::{
      offset: self.next_offset,
      position: seg.size,
    })
    seg.index_saved = false
  }
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
  let seg = self.active()
  self.maybe_anchor()
  let new_size = match (seg.file.append)(frame) {
    Ok(size) => size
    Err(e) => return Err(e)
  }
  seg.size = new_size
  let base = self.next_offset
  self.next_offset += records.length().to_int64()
  match (seg.file.flush)() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match self.maybe_roll() {
    Ok(_) => Ok(base)
    Err(e) => Err(e)
  }
}

///|
/// Reads at most `max_records` entries starting at absolute offset
/// `from`, crossing segment boundaries as needed. Each segment is
/// scanned from the nearest position the caller can cheaply reach
/// (the whole segment today; the sparse index narrows that).
pub fn SegmentedLog::read(
  self : SegmentedLog,
  from : Int64,
  max_records : Int,
) -> Result[Array[LogEntry], LogError] {
  if from < 0L || from > self.next_offset || max_records < 0 {
    return Err(OffsetOutOfRange)
  }
  if from < self.first_offset() {
    // the data was retained away: "it is gone" and "it is empty" are
    // different answers
    return Err(OffsetOutOfRange)
  }
  let out : Array[LogEntry] = []
  if from == self.next_offset || max_records == 0 {
    return Ok(out)
  }
  let start = match self.segment_index_for(from) {
    Some(i) => i
    None => return Err(OffsetOutOfRange)
  }
  for i = start; i < self.segments.length(); i = i + 1 {
    if out.length() >= max_records {
      break
    }
    let seg = self.segments[i]
    // start at the last anchor at or before `from`: the index turns a
    // whole-segment read into a bounded forward scan
    let anchor = anchor_for(seg, from)
    let bytes = match
      (seg.file.read)(anchor.position, seg.size - anchor.position) {
      Ok(bytes) => bytes
      Err(e) => return Err(e)
    }
    let reader = @codec.Reader::new(bytes)
    let mut next = anchor.offset
    while reader.remaining() > 0 && out.length() < max_records {
      match @protocol.decode_frame(reader) {
        Ok(batch) => {
          let count = batch.records.length()
          let batch_end = next + count.to_int64()
          if batch_end > from {
            let raw_skip = (from - next).to_int()
            let skip = if raw_skip < 0 { 0 } else { raw_skip }
            let mut j = skip
            while j < count && out.length() < max_records {
              out.push(LogEntry::{
                offset: next + j.to_int64(),
                record: batch.records[j],
              })
              j += 1
            }
          }
          next = batch_end
        }
        Err(_) => return Err(CorruptFrame)
      }
    }
  }
  Ok(out)
}

///|
/// What a truncation discarded. Reported rather than silent: dropping
/// an unreplicated tail is a correctness action, and an operator (or
/// a test) must be able to see how much was dropped and why.
pub(all) struct TruncateReport {
  /// Records removed from the log end.
  dropped_records : Int
  /// Bytes removed from the segment.
  dropped_bytes : Int
} derive(Debug, Eq, Show)

///|
/// A window of raw frame bytes, exactly as stored.
pub(all) struct RawWindow {
  /// Offset of the first record in the window.
  base_offset : Int64
  /// Records the bytes carry (whole frames only).
  record_count : Int
  /// Concatenated frames, byte-identical to what the leader stored.
  bytes : Bytes
} derive(Debug, Eq, Show)

///|
/// Reads whole frames starting at `from` (which must be a frame
/// boundary) up to `max_records` records, crossing segments. Returns
/// the raw bytes so a follower can append them verbatim: replicating
/// re-encoded records would let two nodes hold the same records in
/// different *framing*, and then "the follower's file is a byte-prefix
/// of the leader's" would stop being true — which is the property the
/// replication gates assert, now per segment.
pub fn SegmentedLog::read_raw(
  self : SegmentedLog,
  from : Int64,
  max_records : Int,
) -> Result[RawWindow, LogError] {
  if from < 0L || from > self.next_offset || max_records < 0 {
    return Err(OffsetOutOfRange)
  }
  if from < self.first_offset() {
    return Err(OffsetOutOfRange)
  }
  let empty = RawWindow::{ base_offset: from, record_count: 0, bytes: b"" }
  if from == self.next_offset || max_records == 0 {
    return Ok(empty)
  }
  let start = match self.segment_index_for(from) {
    Some(i) => i
    None => return Err(OffsetOutOfRange)
  }
  let collected = Buffer::Buffer()
  let mut taken = 0
  // `started` spans segments: the boundary check below is about *where
  // the caller asked to start*, and that question is answered once —
  // applying it to every segment would refuse a legitimate cross-
  // segment read whose later segments simply start past `from` (P8
  // caught exactly that).
  let mut started = false
  for i = start; i < self.segments.length(); i = i + 1 {
    if taken >= max_records {
      break
    }
    let seg = self.segments[i]
    let anchor = anchor_for(seg, from)
    let bytes = match
      (seg.file.read)(anchor.position, seg.size - anchor.position) {
      Ok(bytes) => bytes
      Err(e) => return Err(e)
    }
    let reader = @codec.Reader::new(bytes)
    let mut next = anchor.offset
    // a later segment contributes from its very first frame: `started`
    // was decided in an earlier one
    let mut start_byte : Int? = if started { Some(0) } else { None }
    let mut end_byte = 0
    while reader.remaining() > 0 {
      let before = reader.position()
      match @protocol.decode_frame(reader) {
        Ok(batch) => {
          let count = batch.records.length()
          let batch_end = next + count.to_int64()
          if !started && batch_end > from {
            if next != from {
              // `from` falls inside a frame: refuse rather than slice
              // a batch, which would invent a boundary the leader does
              // not have
              return Err(OffsetOutOfRange)
            }
            started = true
            start_byte = Some(before)
          }
          if started {
            if taken + count > max_records {
              break
            }
            taken += count
            end_byte = reader.position()
          }
          next = batch_end
        }
        Err(_) => return Err(CorruptFrame)
      }
    }
    match start_byte {
      None => ()
      Some(start_at) =>
        collected.write_bytes(bytes[start_at:end_byte].to_owned())
    }
  }
  Ok(RawWindow::{
    base_offset: from,
    record_count: taken,
    bytes: collected.to_bytes(),
  })
}

///|
/// Appends pre-encoded frame bytes as-is. This is the replication
/// write path: the follower stores what the leader stored.
///
/// The frame offsets must line up exactly with this log's next offset
/// — a hole or an overlap is refused, because either one silently
/// breaks the offset contract every reader depends on.
///
/// Frames are appended **one at a time with the roll check after
/// each**, which is what the leader did when it stored them: the two
/// nodes therefore segment identically, and "the follower's segment is
/// a byte-prefix of the leader's" survives segmentation.
pub fn SegmentedLog::append_raw(
  self : SegmentedLog,
  bytes : Bytes,
  record_count : Int,
) -> Result[Unit, LogError] {
  if record_count <= 0 {
    return Ok(())
  }
  if bytes.length() == 0 {
    return Err(CorruptFrame)
  }
  let reader = @codec.Reader::new(bytes)
  let mut next = self.next_offset
  let mut seen = 0
  while reader.remaining() > 0 {
    let before = reader.position()
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        if batch.base_offset != next {
          return Err(OffsetOutOfRange)
        }
        let after = reader.position()
        let seg = self.active()
        self.maybe_anchor()
        let new_size = match (seg.file.append)(bytes[before:after].to_owned()) {
          Ok(size) => size
          Err(e) => return Err(e)
        }
        seg.size = new_size
        next += batch.records.length().to_int64()
        seen += batch.records.length()
        // the log's end moves *as frames land*, not once at the end: a
        // roll reads it to name the next segment, and a stale value
        // would name it after the segment that already exists (P8
        // caught this: rolling silently reused base 0)
        self.next_offset = next
        match (seg.file.flush)() {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        match self.maybe_roll() {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      Err(_) => return Err(CorruptFrame)
    }
  }
  if seen != record_count {
    return Err(CorruptFrame)
  }
  Ok(())
}

///|
/// Drops every segment above `keep_index`, reporting their bytes. Used
/// by both truncation forms: a truncation that lands in an earlier
/// segment removes the later ones entirely.
fn SegmentedLog::drop_segments_after(
  self : SegmentedLog,
  keep_index : Int,
) -> Result[Int, LogError] {
  let mut dropped_bytes = 0
  while self.segments.length() > keep_index + 1 {
    let last = self.segments[self.segments.length() - 1]
    match (self.store.remove)(last.base) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    dropped_bytes += last.size
    let kept : Array[LogSegment] = []
    for i = 0; i < self.segments.length() - 1; i = i + 1 {
      kept.push(self.segments[i])
    }
    self.segments.clear()
    for seg in kept {
      self.segments.push(seg)
    }
  }
  Ok(dropped_bytes)
}

///|
/// Cuts the log back to `offset`, which must be a frame boundary:
/// segments above the target segment go away entirely, and the target
/// segment is cut inside. This is the *voluntary* counterpart of crash
/// recovery: a replica whose tail was never replicated drops it here,
/// and the discard is reported (AGENTS §5: never silent).
pub fn SegmentedLog::truncate_to(
  self : SegmentedLog,
  offset : Int64,
) -> Result[TruncateReport, LogError] {
  match self.drop_segments_after_checked(offset, false) {
    Ok(report) => Ok(report)
    Err(e) => Err(e)
  }
}

///|
/// The boundary variant of `truncate_to`: when `offset` lands inside a
/// frame, the cut goes to the frame's start and replication re-appends
/// the tail. The leader's log end need not fall on one of *this* log's
/// boundaries — the batches differ, that is what divergence means —
/// and storing half a batch is not a thing this log does.
pub fn SegmentedLog::truncate_to_boundary(
  self : SegmentedLog,
  offset : Int64,
) -> Result[TruncateReport, LogError] {
  match self.drop_segments_after_checked(offset, true) {
    Ok(report) => Ok(report)
    Err(e) => Err(e)
  }
}

///|
/// The shared implementation of both truncation forms.
fn SegmentedLog::drop_segments_after_checked(
  self : SegmentedLog,
  offset : Int64,
  to_boundary : Bool,
) -> Result[TruncateReport, LogError] {
  if offset < 0L || offset > self.next_offset {
    return Err(OffsetOutOfRange)
  }
  if offset < self.first_offset() {
    // data below the oldest segment was retained away: a truncation
    // cannot reach into it
    return Err(OffsetOutOfRange)
  }
  if offset == self.next_offset {
    return Ok(TruncateReport::{ dropped_records: 0, dropped_bytes: 0 })
  }
  let target = match self.segment_index_for(offset) {
    Some(i) => i
    None => return Err(OffsetOutOfRange)
  }
  let removed_bytes = match self.drop_segments_after(target) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let seg = self.segments[target]
  let bytes = match (seg.file.read)(0, seg.size) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let reader = @codec.Reader::new(bytes)
  let mut next = seg.base
  let mut cut : Int? = None
  while reader.remaining() > 0 {
    let before = reader.position()
    match @protocol.decode_frame(reader) {
      Ok(batch) => {
        let count = batch.records.length().to_int64()
        if next == offset || (to_boundary && next + count > offset) {
          cut = Some(before)
          break
        }
        if next + count > offset {
          // offset lands inside a frame and this form refuses to slice
          return Err(OffsetOutOfRange)
        }
        next += count
      }
      Err(_) => return Err(CorruptFrame)
    }
  }
  let cut_at = match cut {
    Some(cut) => cut
    None =>
      // the target segment has no frame at or before the target: the
      // cut is at its end, and `next` is where the log now ends
      seg.size
  }
  if cut_at < seg.size {
    match (seg.file.truncate)(cut_at) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let dropped_records = (self.next_offset - next).to_int()
  let in_segment_bytes = seg.size - cut_at
  seg.size = cut_at
  self.next_offset = next
  // an emptied *trailing* segment is not a segment: keep the log
  // ending on a segment that has content, unless it is the only one
  if seg.size == 0 && self.segments.length() > 1 {
    match (self.store.remove)(seg.base) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let kept : Array[LogSegment] = []
    for i = 0; i < self.segments.length() - 1; i = i + 1 {
      kept.push(self.segments[i])
    }
    self.segments.clear()
    for s in kept {
      self.segments.push(s)
    }
  }
  Ok(TruncateReport::{
    dropped_records,
    dropped_bytes: in_segment_bytes + removed_bytes,
  })
}
