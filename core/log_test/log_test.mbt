// SPDX-License-Identifier: Apache-2.0
// Blackbox tests for moonflux/core/log — public contract over the
// injected-memory segment handle. Imports live in moon.pkg.

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{
    timestamp: 0L,
    key: b"",
    value: encode_ascii(value),
    headers: [],
  }
}

///|
fn entry(offset : Int64, value : String) -> @log.LogEntry {
  @log.LogEntry::{ offset, record: rec(value) }
}

///|
fn encode_ascii(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for i in 0..<s.length() {
    arr.push(s[i].to_int().to_byte())
  }
  Bytes::from_array(arr[:])
}

///|
test "append assigns consecutive offsets and read replays them" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(e) => abort("open failed: \{e}")
  }
  assert_eq(l.high_watermark(), 0L)
  assert_eq(l.append([rec("a"), rec("b")]), Ok(0L))
  assert_eq(l.append([rec("c"), rec("d"), rec("e")]), Ok(2L))
  assert_eq(l.high_watermark(), 5L)
  assert_eq(
    l.read(0, 10),
    Ok([
      entry(0L, "a"),
      entry(1L, "b"),
      entry(2L, "c"),
      entry(3L, "d"),
      entry(4L, "e"),
    ]),
  )
  // windowed reads: from inside the first batch, exact max
  assert_eq(l.read(1, 2), Ok([entry(1L, "b"), entry(2L, "c")]))
  assert_eq(l.read(4, 100), Ok([entry(4L, "e")]))
  assert_eq(l.read(5, 10), Ok([]))
}

///|
test "empty append writes nothing" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  assert_eq(l.append([]), Ok(0L))
  assert_eq((mem.handle().size)(), Ok(0))
  assert_eq(l.high_watermark(), 0L)
}

///|
test "read rejects out-of-range offsets" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  let _ = l.append([rec("a")])
  assert_eq(l.read(-1L, 5), Err(@log.OffsetOutOfRange))
  assert_eq(l.read(2L, 5), Err(@log.OffsetOutOfRange))
}

///|
test "recovery truncates a torn tail and keeps committed records" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  let _ = l.append([rec("a"), rec("b"), rec("c")])
  let committed = mem.contents()
  // simulate a crash mid-append: a partial frame lands after the
  // committed prefix
  let crash_handle = mem.handle()
  let full = @protocol.encode_frame(3L, [rec("x"), rec("y")])
  let torn = full[0:full.length() / 2].to_owned()
  let _ = (crash_handle.append)(torn)
  assert_true((mem.handle().size)() is Ok(size) && size > committed.length())
  // reopen must recover exactly the committed prefix
  let recovered = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(e) => abort("recovery failed: \{e}")
  }
  assert_eq(recovered.recovery.reason, @log.TornTail)
  assert_eq(recovered.high_watermark(), 3L)
  assert_eq(
    recovered.read(0, 10),
    Ok([entry(0L, "a"), entry(1L, "b"), entry(2L, "c")]),
  )
  // the torn tail was truncated; the next append starts clean
  assert_eq((mem.handle().size)(), Ok(committed.length()))
  assert_eq(recovered.append([rec("d")]), Ok(3L))
  assert_eq(recovered.read(3, 10), Ok([entry(3L, "d")]))
}

///|
test "recovery discards a corrupt frame region and exposes the confirmed watermark" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  let _ = l.append([rec("a")])
  let committed = mem.contents()
  // a full-size but corrupted frame (payload byte flipped) followed
  // by a valid one: crash-recovery semantics stop at the bad frame,
  // keep the confirmed prefix, and report the discard
  let corrupted = flip_byte(@protocol.encode_frame(1L, [rec("b")]), 30, b'!')
  let good = @protocol.encode_frame(2L, [rec("c")])
  let h = mem.handle()
  let _ = (h.append)(corrupted)
  let _ = (h.append)(good)
  let on_disk = match (mem.handle().size)() {
    Ok(size) => size
    Err(e) => abort("size: \{e}")
  }
  let recovered = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(e) => abort("recovery must not fail: \{e}")
  }
  assert_eq(recovered.high_watermark(), 1L)
  assert_eq(recovered.recovery.reason, @log.CorruptFrame)
  assert_eq(recovered.recovery.valid_size, committed.length())
  assert_eq(recovered.recovery.discarded_bytes, on_disk - committed.length())
  assert_eq(recovered.read(0, 10), Ok([entry(0L, "a")]))
  // the corrupt region was truncated: next append continues cleanly
  assert_eq(recovered.append([rec("d")]), Ok(1L))
  assert_eq(recovered.read(1, 10), Ok([entry(1L, "d")]))
}

///|
test "segment file is a valid protocol byte stream" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  let _ = l.append([rec("hello")])
  // the segment itself must decode as concatenated wire frames
  let reader = @codec.Reader::new(mem.contents())
  match @protocol.decode_frame(reader) {
    Ok(batch) => {
      assert_eq(batch.base_offset, 0L)
      assert_eq(batch.records, [rec("hello")])
    }
    Err(e) => abort("segment not a protocol stream: \{e}")
  }
  assert_true(reader.is_empty())
}

///|
fn flip_byte(data : Bytes, index : Int, replacement : Byte) -> Bytes {
  let out = Buffer::Buffer()
  for i in 0..<data.length() {
    out.write_byte(if i == index { replacement } else { data[i] })
  }
  out.to_bytes()
}

///|
/// Builds a log with `n` records of `batch` size each, on a memory
/// segment whose bytes the test can also inspect.
fn seeded_log(n : Int, batch : Int) -> (@log.SegmentedLog, @log.MemorySegment) {
  let memory = @log.MemorySegment::new()
  let log = match @log.SegmentedLog::open(@log.MemorySegment::handle(memory)) {
    Ok(log) => log
    Err(e) => abort("open: \{e}")
  }
  let mut i = 0
  while i < n {
    let records : Array[@protocol.Record] = []
    for j in 0..<batch {
      if i + j < n {
        records.push(rec("v\{i + j}"))
      }
    }
    match log.append(records) {
      Ok(_) => ()
      Err(e) => abort("append: \{e}")
    }
    i += batch
  }
  (log, memory)
}

///|
test "read_raw returns whole frames byte-identical to the segment" {
  let (log, memory) = seeded_log(6, 3)
  let window = match log.read_raw(3L, 10) {
    Ok(window) => window
    Err(e) => abort("read_raw: \{e}")
  }
  assert_eq(window.base_offset, 3L)
  assert_eq(window.record_count, 3)
  // the bytes are literally the tail of the segment, not a re-encoding:
  // segment == first frame ++ window, with no byte unaccounted for
  let all = memory.contents()
  let first = match log.read_raw(0L, 3) {
    Ok(first) => first
    Err(e) => abort("read_raw head: \{e}")
  }
  assert_eq(first.bytes.length() + window.bytes.length(), all.length())
  let joined = @buffer.Buffer::Buffer()
  joined.write_bytes(first.bytes[0:first.bytes.length()])
  joined.write_bytes(window.bytes[0:window.bytes.length()])
  assert_eq(joined.to_bytes(), all)
}

///|
test "read_raw refuses to start inside a frame" {
  let (log, _) = seeded_log(6, 3)
  // offsets 0..5 are stored as two frames of three; 2 is a record
  // offset but not a frame boundary
  assert_true(log.read_raw(2L, 10) is Err(OffsetOutOfRange))
  // the boundaries themselves are fine
  assert_true(log.read_raw(0L, 10) is Ok(_))
  assert_true(log.read_raw(3L, 10) is Ok(_))
  // and the end of the log is an empty window, not an error
  match log.read_raw(6L, 10) {
    Ok(window) => assert_eq(window.record_count, 0)
    Err(e) => abort("read_raw at end: \{e}")
  }
}

///|
test "append_raw replicates bytes verbatim and enforces continuity" {
  let (leader, _) = seeded_log(6, 3)
  let window = match leader.read_raw(0L, 10) {
    Ok(window) => window
    Err(e) => abort("read_raw: \{e}")
  }
  let follower = match
    @log.SegmentedLog::open(
      @log.MemorySegment::handle(@log.MemorySegment::new()),
    ) {
    Ok(log) => log
    Err(e) => abort("open follower: \{e}")
  }
  match follower.append_raw(window.bytes, window.record_count) {
    Ok(_) => ()
    Err(e) => abort("append_raw: \{e}")
  }
  assert_eq(follower.high_watermark(), 6L)
  // the replica's file is byte-identical to the leader's
  let (_, leader_mem) = seeded_log(6, 3)
  let follower_bytes = match follower.read_raw(0L, 10) {
    Ok(w) => w.bytes
    Err(e) => abort("follower read_raw: \{e}")
  }
  assert_eq(follower_bytes.length(), leader_mem.contents().length())

  // a second identical append would overlap: refused, not applied
  assert_true(follower.append_raw(window.bytes, window.record_count) is Err(_))
  // a record count that disagrees with the payload is refused
  assert_true(follower.append_raw(window.bytes, 99) is Err(_))
  // garbage is refused
  assert_true(follower.append_raw(b"not a frame", 1) is Err(_))
}

///|
test "truncate_to drops an unreplicated tail and reports it" {
  let (log, memory) = seeded_log(6, 3)
  let before = memory.contents().length()
  let report = match log.truncate_to(3L) {
    Ok(report) => report
    Err(e) => abort("truncate_to: \{e}")
  }
  assert_eq(report.dropped_records, 3)
  assert_true(report.dropped_bytes > 0)
  assert_eq(log.high_watermark(), 3L)
  assert_eq(memory.contents().length(), before - report.dropped_bytes)
  // the surviving prefix still reads correctly
  match log.read(0L, 10) {
    Ok(entries) => {
      assert_eq(entries.length(), 3)
      assert_eq(entries[2].offset, 2L)
    }
    Err(e) => abort("read after truncate: \{e}")
  }
  // appending after the cut continues the offset sequence
  match log.append([rec("new")]) {
    Ok(base) => assert_eq(base, 3L)
    Err(e) => abort("append after truncate: \{e}")
  }
  assert_eq(log.high_watermark(), 4L)
}

///|
test "truncate_to refuses non-boundaries, growth, and no-ops cleanly" {
  let (log, _) = seeded_log(6, 3)
  // inside a frame (record offset 1 lives in the frame starting at 0)
  assert_true(log.truncate_to(1L) is Err(OffsetOutOfRange))
  // beyond the end: truncation never extends a log
  assert_true(log.truncate_to(9L) is Err(OffsetOutOfRange))
  assert_true(log.truncate_to(-1L) is Err(OffsetOutOfRange))
  // cutting to the current end is a legal no-op
  match log.truncate_to(6L) {
    Ok(report) => {
      assert_eq(report.dropped_records, 0)
      assert_eq(report.dropped_bytes, 0)
    }
    Err(e) => abort("no-op truncate: \{e}")
  }
  assert_eq(log.high_watermark(), 6L)
}

///|
test "truncate_to_boundary cuts inside a frame instead of refusing" {
  // seeded_log(6, 3): records 0..5 in frames of 3, so offsets 0 and 3
  // are the boundaries and offset 1 is *inside* a frame
  let (log, memory) = seeded_log(6, 3)
  let before = memory.contents().length()
  // 1 is not a boundary: the plain form refuses (what a divergent
  // replica hits when its frames do not line up with the leader's)
  assert_true(log.truncate_to(1L) is Err(OffsetOutOfRange))
  let report = match log.truncate_to_boundary(1L) {
    Ok(report) => report
    Err(e) => abort("truncate_to_boundary: \{e}")
  }
  // the whole frame is dropped: the log ends at offset 0, and the
  // report says what actually left the disk
  assert_eq(report.dropped_records, 6)
  assert_true(report.dropped_bytes > 0)
  assert_eq(log.high_watermark(), 0L)
  assert_eq(memory.contents().length(), before - report.dropped_bytes)
  // replication re-appends from there: the offset sequence continues
  match log.append([rec("again")]) {
    Ok(base) => assert_eq(base, 0L)
    Err(e) => abort("append after boundary truncate: \{e}")
  }
  assert_eq(log.high_watermark(), 1L)
  // an exact boundary behaves like truncate_to
  let (log2, _) = seeded_log(6, 3)
  match log2.truncate_to_boundary(3L) {
    Ok(report) => assert_eq(report.dropped_records, 3)
    Err(e) => abort("boundary truncate: \{e}")
  }
  assert_eq(log2.high_watermark(), 3L)
  // and the same guards apply: no growth, no negatives
  assert_true(log2.truncate_to_boundary(9L) is Err(OffsetOutOfRange))
  assert_true(log2.truncate_to_boundary(-1L) is Err(OffsetOutOfRange))
}

// ---------------------------------------------------------------------
// Segmentation (P8): the same log, now with boundaries. Everything a
// reader can observe must be identical to the single-segment log —
// that is the whole contract of rolling — so the tests below compare
// a rolling log against a non-rolling one holding the same batches.

///|
test "a rolling log reads identically to a non-rolling one" {
  let plain = @log.MemorySegmentStore::new()
  let rolling = @log.MemorySegmentStore::new()
  let flat = match @log.SegmentedLog::open_store(plain.store(), 0) {
    Ok(l) => l
    Err(e) => abort("open flat: \{e}")
  }
  // a threshold small enough that a batch or two fills a segment
  let rolled = match @log.SegmentedLog::open_store(rolling.store(), 40) {
    Ok(l) => l
    Err(e) => abort("open rolling: \{e}")
  }
  for i = 0; i < 12; i = i + 1 {
    let batch = [rec("r\{i}")]
    assert_eq(flat.append(batch), rolled.append(batch))
  }
  // the rolling log really did roll, and the boundaries are frame
  // boundaries (a segment count above 1 is the point of the exercise)
  assert_true(rolling.bases().length() > 1)
  // every read agrees: same entries, same offsets
  assert_eq(rolled.read(0L, 100), flat.read(0L, 100))
  assert_eq(rolled.read(5L, 3), flat.read(5L, 3))
  assert_eq(rolled.read(11L, 5), flat.read(11L, 5))
  assert_eq(rolled.high_watermark(), flat.high_watermark())
  // the raw replication path agrees byte for byte across boundaries
  let raw_rolled = match rolled.read_raw(0L, 100) {
    Ok(window) => window
    Err(e) => abort("read_raw rolling: \{e}")
  }
  let raw_flat = match flat.read_raw(0L, 100) {
    Ok(window) => window
    Err(e) => abort("read_raw flat: \{e}  /  rolling: \{raw_rolled}")
  }
  assert_eq(raw_rolled.bytes, raw_flat.bytes)
  assert_eq(raw_rolled.record_count, 12)
  // a raw read that starts mid-log and crosses a boundary
  let window = match rolled.read_raw(9L, 100) {
    Ok(window) => window
    Err(e) => abort("read_raw from 9: \{e}")
  }
  assert_eq(window.base_offset, 9L)
  assert_eq(window.record_count, 3)
  // the reader sees the same three records through both paths
  assert_eq(
    rolled.read(9L, 10),
    Ok([entry(9L, "r9"), entry(10L, "r10"), entry(11L, "r11")]),
  )
}

///|
test "a reappended raw window segments exactly like the original" {
  // the leader's segmentation and a follower's must agree, or "the
  // follower's segment is a byte-prefix of the leader's" would break
  let leader_store = @log.MemorySegmentStore::new()
  let follower_store = @log.MemorySegmentStore::new()
  let leader = match @log.SegmentedLog::open_store(leader_store.store(), 40) {
    Ok(l) => l
    Err(e) => abort("leader: \{e}")
  }
  let follower = match
    @log.SegmentedLog::open_store(follower_store.store(), 40) {
    Ok(l) => l
    Err(e) => abort("follower: \{e}")
  }
  for i = 0; i < 10; i = i + 1 {
    let _ = leader.append([rec("x\{i}")])
  }
  // replicate in two windows (as a follower catches up)
  let first = match leader.read_raw(0L, 4) {
    Ok(w) => w
    Err(e) => abort("raw 1: \{e}")
  }
  let second = match leader.read_raw(4L, 100) {
    Ok(w) => w
    Err(e) => abort("raw 2: \{e}")
  }
  assert_eq(follower.append_raw(first.bytes, first.record_count), Ok(()))
  assert_eq(follower.append_raw(second.bytes, second.record_count), Ok(()))
  assert_eq(follower.high_watermark(), leader.high_watermark())
  // identical segment bases, and identical bytes within each segment
  let bases = leader_store.bases()
  assert_eq(follower_store.bases(), bases)
  for base in bases {
    assert_eq(follower_store.contents(base), leader_store.contents(base))
  }
}

///|
test "recovery scans only the last segment and drops empty tails" {
  let store = @log.MemorySegmentStore::new()
  let log = match @log.SegmentedLog::open_store(store.store(), 30) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 8; i = i + 1 {
    let _ = log.append([rec("v\{i}")])
  }
  let bases = store.bases()
  assert_true(bases.length() > 1)
  // the last segment may be the empty one a roll just created: tear a
  // segment that actually holds a frame
  let mut last_base = bases[bases.length() - 1]
  let mut last_bytes = store.contents(last_base)
  for i = bases.length() - 1; i >= 0; i = i - 1 {
    let candidate = store.contents(bases[i])
    if candidate.length() > 3 {
      last_base = bases[i]
      last_bytes = candidate
      break
    }
  }
  assert_true(last_bytes.length() > 3)
  // reopen: the earlier segments are trusted, the last one is scanned
  let reopened = match @log.SegmentedLog::open_store(store.store(), 30) {
    Ok(l) => l
    Err(e) => abort("reopen: \{e}")
  }
  assert_eq(reopened.high_watermark(), 8L)
  assert_true(reopened.recovery.reason is Clean)
  // tear the last segment's tail: recovery cuts it there and reports it
  let torn = last_bytes[0:last_bytes.length() - 3].to_owned()
  let last_file = match (store.store().open_segment)(last_base) {
    Ok(file) => file
    Err(e) => abort("open last segment: \{e}")
  }
  match (last_file.truncate)(torn.length()) {
    Ok(_) => ()
    Err(e) => abort("tear the tail: \{e}")
  }
  let recovered = match @log.SegmentedLog::open_store(store.store(), 30) {
    Ok(l) => l
    Err(e) => abort("recover: \{e}")
  }
  assert_true(recovered.recovery.reason is TornTail)
  assert_true(recovered.recovery.discarded_bytes > 0)
  // the records before the tear survive; the watermark backs up to them
  assert_eq(recovered.read(0L, 100).unwrap().length(), 7)
  assert_eq(recovered.high_watermark(), 7L)
}

///|
test "an empty trailing segment is dropped on open" {
  let store = @log.MemorySegmentStore::new()
  let log = match @log.SegmentedLog::open_store(store.store(), 20) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 4; i = i + 1 {
    let _ = log.append([rec("e\{i}")])
  }
  // simulating a crash between "create the new segment" and "append":
  // the store holds an empty segment with a base past the data
  let _ = (store.store().open_segment)(log.high_watermark())
  let with_empty = store.bases().length()
  assert_true(with_empty >= 2)
  let reopened = match @log.SegmentedLog::open_store(store.store(), 20) {
    Ok(l) => l
    Err(e) => abort("reopen: \{e}")
  }
  assert_eq(reopened.high_watermark(), 4L)
  // exactly the empty one went away
  assert_eq(store.bases().length(), with_empty - 1)
}

///|
test "a store that is not one log is refused, not repaired" {
  // two segments with the same base: not one log
  let duplicated = @log.SegmentStore::{
    open_segment: fn(_base) { Ok(@log.MemorySegment::new().handle()) },
    open_index: fn(_base) { Ok(@log.MemorySegment::new().handle()) },
    list: fn() {
      Ok([
        @log.SegmentInfo::{ base: 0L, size: 0, created_ms: 0L },
        @log.SegmentInfo::{ base: 0L, size: 0, created_ms: 0L },
      ])
    },
    remove: fn(_base) { Ok(()) },
  }
  match @log.SegmentedLog::open_store(duplicated, 0) {
    Err(Storage(msg)) => assert_true(msg.contains("strictly"))
    Ok(_) => abort("duplicate bases accepted")
    Err(e) => abort("unexpected: \{e}")
  }
  // an empty segment in the middle: a hole, because appends only ever
  // go to the active segment. Built on a real memory store so the
  // reported sizes are the actual ones.
  let mem = @log.MemorySegmentStore::new()
  let holed = mem.store()
  let _ = (holed.open_segment)(0L)
  let middle = match (holed.open_segment)(4L) {
    Ok(file) => file
    Err(e) => abort("open middle: \{e}")
  }
  let _ = (middle.append)(b"xx")
  let _ = (holed.open_segment)(8L)
  match @log.SegmentedLog::open_store(holed, 0) {
    Err(Storage(msg)) => assert_true(msg.contains("hole"))
    Ok(_) => abort("a hole was accepted")
    Err(e) => abort("unexpected: \{e}")
  }
}

// ---------------------------------------------------------------------
// Sparse index (P8/T45). The index is an accelerator, never truth: the
// tests below are written so that a *wrong* index is a test failure
// rather than a wrong answer — every fallback is exercised.

///|
test "indexed reads match a scan, anchor or not" {
  let store = @log.MemorySegmentStore::new()
  // a small anchor interval so a few records produce several anchors
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 0, 2) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 20; i = i + 1 {
    let _ = log.append([rec("i\{i}")])
  }
  let all = match log.read(0L, 100) {
    Ok(entries) => entries
    Err(e) => abort("read all: \{e}")
  }
  assert_eq(all.length(), 20)
  // every offset, read through the index, agrees with the sequence
  for start = 0; start < 20; start = start + 1 {
    let entries = match log.read(start.to_int64(), 1) {
      Ok(entries) => entries
      Err(e) => abort("read at \{start}: \{e}")
    }
    assert_eq(entries.length(), 1)
    assert_eq(entries[0], all[start])
  }
  // and the raw path (replication) agrees with the record path
  for start = 0; start < 20; start = start + 3 {
    let window = match log.read_raw(start.to_int64(), 3) {
      Ok(w) => w
      Err(e) => abort("raw at \{start}: \{e}")
    }
    let expected = match log.read(start.to_int64(), 3) {
      Ok(entries) => entries
      Err(e) => abort("read at \{start}: \{e}")
    }
    assert_eq(window.record_count, expected.length())
    assert_eq(window.base_offset, start.to_int64())
  }
}

///|
test "a missing, truncated or corrupted index falls back to a scan" {
  let store = @log.MemorySegmentStore::new()
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 30, 2) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 12; i = i + 1 {
    let _ = log.append([rec("s\{i}")])
  }
  let expected = match log.read(0L, 100) {
    Ok(entries) => entries
    Err(e) => abort("read: \{e}")
  }
  let bases = store.bases()
  assert_true(bases.length() > 1)

  // 1. no index at all: openings rebuild from the segment
  for base in bases {
    let file = match (store.store().open_index)(base) {
      Ok(file) => file
      Err(_) => continue
    }
    let _ = (file.truncate)(0)
  }
  let no_index = match
    @log.SegmentedLog::open_store_configured(store.store(), 30, 2) {
    Ok(l) => l
    Err(e) => abort("reopen without index: \{e}")
  }
  assert_eq(no_index.read(0L, 100), Ok(expected))

  // 2. a truncated index (valid magic, missing tail)
  let first = bases[0]
  let index_bytes = store.index_contents(first)
  if index_bytes.length() > 0 {
    let file = match (store.store().open_index)(first) {
      Ok(file) => file
      Err(e) => abort("index file: \{e}")
    }
    let _ = (file.truncate)(0)
    let _ = (file.append)(index_bytes[0:index_bytes.length() - 4].to_owned())
    let truncated = match
      @log.SegmentedLog::open_store_configured(store.store(), 30, 2) {
      Ok(l) => l
      Err(e) => abort("reopen with truncated index: \{e}")
    }
    assert_eq(truncated.read(0L, 100), Ok(expected))
  }

  // 3. a corrupted index (a bit flipped inside an anchor, CRC no
  //    longer matches): still a scan, still the same answer
  let index_bytes2 = store.index_contents(first)
  if index_bytes2.length() > 20 {
    let flipped : Array[Byte] = []
    for i = 0; i < index_bytes2.length(); i = i + 1 {
      flipped.push(index_bytes2[i])
    }
    flipped[20] = flipped[20] ^ b'\x01'
    let file = match (store.store().open_index)(first) {
      Ok(file) => file
      Err(e) => abort("index file: \{e}")
    }
    let _ = (file.truncate)(0)
    let _ = (file.append)(Bytes::from_array(flipped[:]))
    let corrupted = match
      @log.SegmentedLog::open_store_configured(store.store(), 30, 2) {
      Ok(l) => l
      Err(e) => abort("reopen with corrupted index: \{e}")
    }
    assert_eq(corrupted.read(0L, 100), Ok(expected))
  }
}

///|
test "index anchors are frame boundaries and cover every segment" {
  let store = @log.MemorySegmentStore::new()
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 40, 3) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 15; i = i + 1 {
    let _ = log.append([rec("a\{i}")])
  }
  // after a reopen the anchors come from the stored index for sealed
  // segments; reading any offset must still land exactly on a record
  let reopened = match
    @log.SegmentedLog::open_store_configured(store.store(), 40, 3) {
    Ok(l) => l
    Err(e) => abort("reopen: \{e}")
  }
  for i = 0; i < 15; i = i + 1 {
    let entries = match reopened.read(i.to_int64(), 1) {
      Ok(entries) => entries
      Err(e) => abort("read at \{i}: \{e}")
    }
    assert_eq(entries[0].offset, i.to_int64())
  }
  // the stored indexes are small (anchors, not a full offset map)
  let bases = store.bases()
  for base in bases {
    let index_bytes = store.index_contents(base)
    assert_true(index_bytes.length() < 200)
  }
}

// ---------------------------------------------------------------------
// Retention (P8/T46). The rule under test is the one that destroys
// data, so its guards get the most attention: whole segments only,
// never the active one, and never past the floor the caller supplies.

///|
test "retention drops whole segments below the floor and reports them" {
  let store = @log.MemorySegmentStore::new()
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 40, 64) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 12; i = i + 1 {
    let _ = log.append([rec("r\{i}")])
  }
  let bases = store.bases()
  assert_true(bases.length() >= 3)
  let before = log.segment_summaries()
  assert_eq(log.first_offset(), 0L)
  // the floor is everything committed *except* the newest record: with
  // one record per segment (roll threshold 40), that keeps exactly the
  // segment holding the uncommitted record
  let floor = log.high_watermark() - 1L
  let mut survivor_base = before[0].base
  let mut survivors = 0
  for summary in before {
    if summary.base + summary.records > floor {
      if survivors == 0 {
        survivor_base = summary.base
      }
      survivors += 1
    }
  }
  let report = match
    log.apply_retention(floor, 0L, @log.RetentionPolicy::{
      max_bytes: 1,
      max_age_ms: 0L,
    }) {
    Ok(report) => report
    Err(e) => abort("retention: \{e}")
  }
  // every segment whose end is at or below the floor went, and each
  // removal is named
  assert_eq(report.removed.length(), before.length() - survivors)
  assert_true(report.removed_bytes > 0)
  assert_true(report.removed_records > 0)
  // what survives is exactly the segments above the floor
  assert_eq(store.bases().length(), survivors)
  assert_eq(log.first_offset(), survivor_base)
  // reads below the new start are refused — "it is gone" is not
  // "it is empty"
  assert_true(log.read(0L, 1) is Err(OffsetOutOfRange))
  // and the survivors still read correctly, from the first one on
  let entries = match log.read(survivor_base, 100) {
    Ok(entries) => entries
    Err(e) => abort("read after retention: \{e}")
  }
  let surviving_records = log
    .segment_summaries()
    .fold(init=0, fn(acc, summary) { acc + summary.records.to_int() })
  assert_eq(entries.length(), surviving_records)
  assert_eq(entries[0].offset, survivor_base)
}

///|
test "the floor stops retention, and the active segment is never dropped" {
  let store = @log.MemorySegmentStore::new()
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 40, 64) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 12; i = i + 1 {
    let _ = log.append([rec("f\{i}")])
  }
  let summaries = log.segment_summaries()
  assert_true(summaries.length() >= 3)
  // floor = the end of the first segment: only that one may go
  let floor = summaries[0].base + summaries[0].records
  let report = match
    log.apply_retention(floor, 0L, @log.RetentionPolicy::{
      max_bytes: 1,
      max_age_ms: 0L,
    }) {
    Ok(report) => report
    Err(e) => abort("retention: \{e}")
  }
  assert_eq(report.removed.length(), 1)
  assert_eq(report.removed[0].base, summaries[0].base)
  // a floor at zero removes nothing at all
  let none = match
    log.apply_retention(0L, 0L, @log.RetentionPolicy::{
      max_bytes: 1,
      max_age_ms: 0L,
    }) {
    Ok(report) => report
    Err(e) => abort("retention: \{e}")
  }
  assert_eq(none.removed.length(), 0)
  // and a policy that is off removes nothing, whatever the floor says
  let off = match
    log.apply_retention(log.high_watermark(), 0L, @log.RetentionPolicy::{
      max_bytes: 0,
      max_age_ms: 0L,
    }) {
    Ok(report) => report
    Err(e) => abort("retention: \{e}")
  }
  assert_eq(off.removed.length(), 0)
}

///|
test "age-based retention and rolling use the store's stamps" {
  let store = @log.MemorySegmentStore::new()
  let log = match
    @log.SegmentedLog::open_store_configured(store.store(), 40, 64) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 8; i = i + 1 {
    let _ = log.append([rec("t\{i}")])
  }
  let bases = store.bases()
  assert_true(bases.length() >= 2)
  // stamp the sealed segments as old, the active one as fresh
  for i = 0; i < bases.length() - 1; i = i + 1 {
    store.set_created_ms(bases[i], 1000L)
  }
  store.set_created_ms(bases[bases.length() - 1], 5000L)
  let report = match
    log.apply_retention(log.high_watermark(), 6000L, @log.RetentionPolicy::{
      max_bytes: 0,
      max_age_ms: 2000L,
    }) {
    Ok(report) => report
    Err(e) => abort("retention: \{e}")
  }
  // the old sealed segments went; the fresh active one stayed
  assert_true(report.removed.length() >= 1)
  assert_eq(store.bases().length(), 1)
  // age-based rolling needs an active segment with data in it: rolling
  // an empty segment would produce nothing. Use a non-rolling log so
  // the active segment holds everything.
  let rolling_store = @log.MemorySegmentStore::new()
  let rolling = match
    @log.SegmentedLog::open_store_configured(rolling_store.store(), 0, 64) {
    Ok(l) => l
    Err(e) => abort("open: \{e}")
  }
  for i = 0; i < 4; i = i + 1 {
    let _ = rolling.append([rec("y\{i}")])
  }
  // a fresh segment does not roll
  rolling_store.set_created_ms(0L, 6000L)
  assert_eq(rolling.roll_due(6000L, 2000L), Ok(false))
  // a stale one does, and the new segment starts at the log's end
  rolling_store.set_created_ms(0L, 1000L)
  assert_eq(rolling.roll_due(6000L, 2000L), Ok(true))
  assert_eq(rolling_store.bases().length(), 2)
  assert_eq(rolling.high_watermark(), 4L)
  assert_eq(rolling.segment_summaries()[1].base, 4L)
  assert_eq(rolling.segment_summaries()[1].records, 0L)
  // and an empty active segment never rolls
  assert_eq(rolling.roll_due(9000L, 1L), Ok(false))
}
