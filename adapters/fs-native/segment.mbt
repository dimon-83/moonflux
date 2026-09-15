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
