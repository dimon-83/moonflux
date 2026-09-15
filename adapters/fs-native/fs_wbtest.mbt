// Integration tests for adapters/fs-native — exercise real files
// under a fixed temp root. Only meaningful on the native target; the
// package is excluded from other backends via supported_targets.

///|
fn temp_path(name : String) -> String {
  "/tmp/moonflux_fs_test/\{name}"
}

///|
fn ensure_temp_root() -> Unit {
  let _ = mkdirs("/tmp/moonflux_fs_test")
}

///|
fn bytes_of(s : String) -> Bytes {
  @utf8.encode(s[0:s.length()])
}

///|
test "write_file and read_file round trip" {
  ensure_temp_root()
  let path = temp_path("roundtrip.txt")
  let _ = remove_file(path)
  assert_eq(write_file(path, bytes_of("hello moonflux")), Ok(()))
  assert_eq(read_file(path), Ok(bytes_of("hello moonflux")))
  // overwrite semantics
  assert_eq(write_file(path, bytes_of("abc")), Ok(()))
  assert_eq(read_file(path), Ok(bytes_of("abc")))
  let _ = remove_file(path)
}

///|
test "append mode preserves prior content and pread is positional" {
  ensure_temp_root()
  let path = temp_path("append.log")
  let _ = remove_file(path)
  let f = match File::open_read_write_append(path) {
    Ok(f) => f
    Err(e) => abort("open_append: \{e}")
  }
  let _ = f.write_all(bytes_of("AAAA"))
  let _ = f.write_all(bytes_of("BBBB"))
  assert_eq(f.size(), Ok(8))
  let buf : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  assert_eq(f.pread(buf, 4, 4), Ok(4))
  let arr : Array[Byte] = []
  for i in 0..<4 {
    arr.push(buf[i])
  }
  assert_eq(Bytes::from_array(arr[:]), bytes_of("BBBB"))
  assert_eq(f.flush(), Ok(()))
  assert_eq(f.close(), Ok(()))
  assert_eq(exists(path), Ok(true))
  let _ = remove_file(path)
  assert_eq(exists(path), Ok(false))
}

///|
test "mkdirs creates nested prefixes idempotently" {
  assert_eq(mkdirs("/tmp/moonflux_fs_test/a/b/c"), Ok(()))
  assert_eq(mkdirs("/tmp/moonflux_fs_test/a/b/c"), Ok(()))
  assert_eq(write_file("/tmp/moonflux_fs_test/a/b/c/f.txt", b"x"), Ok(()))
  assert_eq(read_file("/tmp/moonflux_fs_test/a/b/c/f.txt"), Ok(b"x"))
}

///|
test "segment file survives reopen with committed prefix intact" {
  ensure_temp_root()
  let path = temp_path("segment-0.log")
  let _ = remove_file(path)
  let records = fn(value : String) -> @protocol.Record {
    @protocol.Record::{ timestamp: 7L, key: b"", value: @utf8.encode(value[0:value.length()]), headers: [] }
  }
  let entry = fn(offset : Int64, value : String) -> @log.LogEntry {
    @log.LogEntry::{ offset, record: records(value) }
  }
  let first = match open_segment_file(path) {
    Ok(h) => h
    Err(e) => abort("open segment: \{e}")
  }
  let log = match @log.SegmentedLog::open(first) {
    Ok(l) => l
    Err(e) => abort("open log: \{e}")
  }
  assert_eq(
    log.append([records("one"), records("two")]),
    Ok(0L),
  )
  let _ = log.append([records("three")])
  // reopen the same file: recovery must keep all three records
  let second = match open_segment_file(path) {
    Ok(h) => h
    Err(e) => abort("reopen segment: \{e}")
  }
  let recovered = match @log.SegmentedLog::open(second) {
    Ok(l) => l
    Err(e) => abort("recovery: \{e}")
  }
  assert_eq(recovered.high_watermark(), 3L)
  assert_eq(
    recovered.read(0, 10),
    Ok([
      entry(0L, "one"), entry(1L, "two"), entry(2L, "three"),
    ]),
  )
  let _ = remove_file(path)
}
