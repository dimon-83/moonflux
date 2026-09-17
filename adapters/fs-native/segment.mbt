// SPDX-License-Identifier: Apache-2.0
// Bridges real files onto the kernel's injected SegmentFile
// interface, so SegmentedLog can persist to the native filesystem.
// Error mapping is deliberately lossy (FsError -> Storage(msg))
// because the kernel's log semantics only distinguish storage
// failure from log corruption.

///|
fn map_err(e : FsError) -> @log.LogError {
  @log.Storage("\{e}")
}

///|
fn make_segment_file(f : File) -> @log.SegmentFile {
  @log.SegmentFile::{
    read: fn(position, length) {
      if length < 0 || position < 0 {
        return Err(@log.Storage("negative read bounds"))
      }
      let buf : FixedArray[Byte] = FixedArray::make(length, b'\x00')
      match f.pread(buf, length, position) {
        Ok(n) => Ok(Bytes::from_fixedarray(buf, len=n))
        Err(e) => Err(map_err(e))
      }
    },
    append: fn(bytes) {
      match f.write_all(bytes) {
        Ok(_n) => {
          let size = match f.size() {
            Ok(size) => size
            Err(e) => return Err(map_err(e))
          }
          Ok(size)
        }
        Err(e) => Err(map_err(e))
      }
    },
    size: fn() {
      match f.size() {
        Ok(size) => Ok(size)
        Err(e) => Err(map_err(e))
      }
    },
    flush: fn() {
      match f.flush() {
        Ok(_) => Ok(())
        Err(e) => Err(map_err(e))
      }
    },
    truncate: fn(new_size) {
      // POSIX ftruncate through a shim-less route: open a fresh
      // handle in truncate mode would lose append semantics, so go
      // through the dedicated syscall.
      let code = fs_truncate(f.fd, new_size)
      if code < 0 {
        Err(map_err(Io(-code, "ftruncate")))
      } else {
        Ok(())
      }
    },
  }
}

///|
/// Opens (or creates) `path` as a durable commit-log segment for the
/// kernel's `SegmentedLog`. The file is opened in append mode for
/// writes and read positionally, matching the single-writer model.
pub fn open_segment_file(path : String) -> Result[@log.SegmentFile, FsError] {
  let f = match File::open_read_write_append(path) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  Ok(make_segment_file(f))
}

// ---------------------------------------------------------------------
// The segment *store*: a directory holds a partition's segments, one
// file per segment, named by the offset of its first record. The
// kernel owns what a segment means; the layout below is this
// adapter's business, and the naming is the index — a base offset you
// cannot read back from the listing is a segment nobody can recover.

///|
/// `00000000000000000000.log` for base 0, and so on: fixed width so a
/// plain lexicographic listing is also offset order, which makes the
/// filesystem's own ordering the first thing that agrees with the
/// kernel's.
pub fn segment_file_name(base : Int64) -> String {
  let digits = base.to_string()
  let padded = StringBuilder::new()
  for _i = 0; _i < 20 - digits.length(); _i = _i + 1 {
    padded.write_char('0')
  }
  padded.write_string(digits)
  "\{padded.to_string()}.log"
}

///|
/// The index sidecar's name: `00000000000000000000.idx` beside the
/// segment it describes. Same base, different suffix, so the pairing is
/// visible in a directory listing.
pub fn segment_index_name(base : Int64) -> String {
  let digits = base.to_string()
  let padded = StringBuilder::new()
  for _i = 0; _i < 20 - digits.length(); _i = _i + 1 {
    padded.write_char('0')
  }
  padded.write_string(digits)
  "\{padded.to_string()}.idx"
}

///|
/// The base offset encoded in a segment file name, or None when the
/// name is not one of ours.
fn segment_base_of(name : String) -> Int64? {
  if name.length() <= 4 {
    return None
  }
  if name[name.length() - 4:name.length()].to_string() != ".log" {
    return None
  }
  let stem = name[0:name.length() - 4]
  for i = 0; i < stem.length(); i = i + 1 {
    let c = stem[i]
    if c < '0' || c > '9' {
      return None
    }
  }
  let parsed = try? @string.parse_int64(stem)
  match parsed {
    Ok(base) => Some(base)
    Err(_) => None
  }
}

///|
/// Opens (or creates) the partition directory as a segment store.
/// `roll_bytes` and retention live in the kernel; this adapter only
/// answers "what segments exist, open one, drop one".
pub fn open_segment_store(dir : String) -> Result[@log.SegmentStore, FsError] {
  let store : @log.SegmentStore = {
    open_segment: fn(base) {
      match mkdirs(dir) {
        Ok(_) => ()
        Err(e) => return Err(map_err(e))
      }
      match open_segment_file("\{dir}/\{segment_file_name(base)}") {
        Ok(file) => Ok(file)
        Err(e) => Err(map_err(e))
      }
    },
    list: fn() {
      let names = match list_dir(dir) {
        Ok(names) => names
        // a directory that does not exist yet is an empty store, not
        // an error: the first append creates it
        Err(_) => return Ok([])
      }
      let out : Array[@log.SegmentInfo] = []
      for name in names {
        match segment_base_of(name) {
          None => ()
          Some(base) => {
            let path = "\{dir}/\{name}"
            let info = match segment_info_for(path, base) {
              Ok(info) => info
              Err(e) => return Err(e)
            }
            out.push(info)
          }
        }
      }
      Ok(out)
    },
    open_index: fn(base) {
      match mkdirs(dir) {
        Ok(_) => ()
        Err(e) => return Err(map_err(e))
      }
      match open_segment_file("\{dir}/\{segment_index_name(base)}") {
        Ok(file) => Ok(file)
        Err(e) => Err(map_err(e))
      }
    },
    remove: fn(base) {
      // the index goes with its segment: a sidecar with no segment is
      // a lie waiting for a reader
      match remove_file("\{dir}/\{segment_index_name(base)}") {
        Ok(_) => ()
        Err(_) => () // absent is fine
      }
      match remove_file("\{dir}/\{segment_file_name(base)}") {
        Ok(_) => Ok(())
        Err(e) => Err(map_err(e))
      }
    },
  }
  Ok(store)
}

///|
fn segment_info_for(
  path : String,
  base : Int64,
) -> Result[@log.SegmentInfo, @log.LogError] {
  let f = match File::open_read_write_append(path) {
    Ok(f) => f
    Err(e) => return Err(map_err(e))
  }
  let size = match f.size() {
    Ok(size) => size
    Err(e) => return Err(map_err(e))
  }
  // the segment's age is the OS's stamp on the file; the kernel only
  // ever compares it against a `now` the app supplies
  let created_ms = match mtime(path) {
    Ok(stamp) => stamp / 1000000L
    Err(_) => 0L
  }
  Ok(@log.SegmentInfo::{ base, size, created_ms })
}
