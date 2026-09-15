// Blackbox tests for moonflux/core/log — public contract over the
// injected-memory segment handle. Imports live in moon.pkg.

///|
fn rec(value : String) -> @protocol.Record {
  @protocol.Record::{ timestamp: 0L, key: b"", value: encode_ascii(value), headers: [] }
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
      entry(0L, "a"), entry(1L, "b"), entry(2L, "c"), entry(3L, "d"), entry(4L, "e"),
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
test "recovery refuses mid-file corruption instead of guessing" {
  let mem = @log.MemorySegment::new()
  let l = match @log.SegmentedLog::open(mem.handle()) {
    Ok(l) => l
    Err(_) => abort("unreachable")
  }
  let _ = l.append([rec("a")])
  // a full-size but corrupted frame (payload byte flipped) followed
  // by a valid one: silent skipping would lose offsets, so this must
  // surface as CorruptFrame
  let corrupted = flip_byte(@protocol.encode_frame(1L, [rec("b")]), 30, b'!')
  let good = @protocol.encode_frame(2L, [rec("c")])
  let h = mem.handle()
  let _ = (h.append)(corrupted)
  let _ = (h.append)(good)
  match @log.SegmentedLog::open(mem.handle()) {
    Err(@log.CorruptFrame) => ()
    Err(_) => abort("expected CorruptFrame, got another LogError")
    Ok(_) => abort("expected CorruptFrame, but open succeeded")
  }
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
    out.write_byte(if i == index {
      replacement
    } else {
      data[i]
    })
  }
  out.to_bytes()
}
