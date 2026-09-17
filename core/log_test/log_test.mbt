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
