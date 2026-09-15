// SPDX-License-Identifier: Apache-2.0
// Structured facade over the raw FFI: paths as MoonBit strings,
// errors as FsError, platform-specific flags confined to the shim.

///|
/// Failure modes of the native filesystem adapter. `code` carries
/// the errno value when a syscall failed.
pub(all) suberror FsError {
  /// Path or argument rejected before any syscall.
  BadArgument(String)
  /// Underlying syscall failed; `code` is errno, `op` names it.
  Io(Int, String)
} derive(Debug, Eq)

///|
pub impl Show for FsError with fn output(self, logger) {
  match self {
    BadArgument(msg) => logger.write_string("BadArgument(\{msg})")
    Io(code, op) => logger.write_string("Io(errno=\{code}, op=\{op})")
  }
}

///|
fn syscall_result(code : Int, op : String) -> Result[Unit, FsError] {
  if code < 0 {
    Err(Io(-code, op))
  } else {
    Ok(())
  }
}

///|
fn path_bytes(path : String) -> Result[Bytes, FsError] {
  let bytes = @utf8.encode(path[0:path.length()])
  if bytes.length() == 0 || bytes.length() >= 4096 {
    return Err(BadArgument("path length must be 1..4095"))
  }
  Ok(bytes)
}

///|
/// An open file descriptor with positional/append operations. Not
/// thread-safe by design (AGENTS 金规则 5: no shared instances).
pub struct File {
  path : String
  fd : Int
} derive(Debug)

///|
/// Opens `path` read-only.
pub fn File::open_read(path : String) -> Result[File, FsError] {
  File::open_mode(path, 0)
}

///|
/// Opens (or truncates) `path` for writing.
pub fn File::open_write_or_create(path : String) -> Result[File, FsError] {
  File::open_mode(path, 1)
}

///|
/// Opens (or creates) `path` so every write appends atomically.
pub fn File::open_append(path : String) -> Result[File, FsError] {
  File::open_mode(path, 2)
}

///|
/// Opens (or creates) `path` read/write with atomic appends: the
/// mode commit-log segments need (positional preads + appends on
/// one descriptor).
pub fn File::open_read_write_append(path : String) -> Result[File, FsError] {
  File::open_mode(path, 4)
}

///|
fn File::open_mode(path : String, mode : Int) -> Result[File, FsError] {
  let bytes = match path_bytes(path) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let fd = fs_open(bytes, bytes.length(), mode)
  if fd < 0 {
    Err(Io(-fd, "open"))
  } else {
    Ok(File::{ path, fd })
  }
}

///|
/// The path this handle was opened against.
pub fn File::path(self : File) -> String {
  self.path
}

///|
/// Reads up to `len` bytes at absolute `position` into `buf`;
/// returns the number of bytes actually read (0 at end of file).
/// Positional: does not disturb any cursor.
pub fn File::pread(
  self : File,
  buf : FixedArray[Byte],
  len : Int,
  position : Int,
) -> Result[Int, FsError] {
  if len < 0 || len > buf.length() || position < 0 {
    return Err(BadArgument("pread bounds"))
  }
  let n = fs_pread(self.fd, buf, len, position)
  if n < 0 {
    Err(Io(-n, "pread"))
  } else {
    Ok(n)
  }
}

///|
/// Writes `len` bytes from `data` at the current end (append) or
/// cursor position depending on open mode; returns bytes written.
pub fn File::write_all(self : File, data : Bytes) -> Result[Int, FsError] {
  let n = fs_write(self.fd, data, data.length())
  if n < 0 {
    Err(Io(-n, "write"))
  } else {
    Ok(n)
  }
}

///|
/// File size in bytes.
pub fn File::size(self : File) -> Result[Int, FsError] {
  let n = fs_filesize(self.fd)
  if n < 0 {
    Err(Io(-n, "fstat"))
  } else {
    Ok(n)
  }
}

///|
/// Flushes written bytes to stable storage.
pub fn File::flush(self : File) -> Result[Unit, FsError] {
  syscall_result(fs_flush(self.fd), "fsync")
}

///|
/// Closes the descriptor. Idempotent: the second close reports
/// `Io(EBADF, "close")`.
pub fn File::close(self : File) -> Result[Unit, FsError] {
  syscall_result(fs_close(self.fd), "close")
}

///|
/// Creates `path` and every missing prefix (mkdir -p semantics).
pub fn mkdirs(path : String) -> Result[Unit, FsError] {
  let bytes = match path_bytes(path) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  syscall_result(fs_mkdirs(bytes, bytes.length()), "mkdirs")
}

///|
/// Deletes a file.
pub fn remove_file(path : String) -> Result[Unit, FsError] {
  let bytes = match path_bytes(path) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  syscall_result(fs_remove(bytes, bytes.length()), "unlink")
}

///|
/// Last modification time of `path` as nanoseconds since the epoch
/// (used for rule hot-reload change detection; second granularity
/// aliases rapid apply+reload cycles).
pub fn mtime(path : String) -> Result[Int64, FsError] {
  let bytes = match path_bytes(path) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let n = fs_mtime(bytes, bytes.length())
  if n < 0L {
    Err(Io((-n).to_int(), "stat"))
  } else {
    Ok(n)
  }
}

///|
/// True when `path` exists.
pub fn exists(path : String) -> Result[Bool, FsError] {
  let bytes = match path_bytes(path) {
    Ok(bytes) => bytes
    Err(e) => return Err(e)
  }
  let n = fs_exists(bytes, bytes.length())
  if n < 0 {
    Err(Io(-n, "stat"))
  } else {
    Ok(n == 1)
  }
}

///|
/// Reads a whole file into memory. Convenience for small files
/// (configs, spec documents); data paths should stream instead.
pub fn read_file(path : String) -> Result[Bytes, FsError] {
  let f = match File::open_read(path) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  let size = match f.size() {
    Ok(size) => size
    Err(e) => return Err(e)
  }
  let buf : FixedArray[Byte] = FixedArray::make(size, b'\x00')
  let mut filled = 0
  while filled < size {
    let n = match f.pread(buf, size - filled, filled) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if n == 0 {
      break // file shrank concurrently; return what we have
    }
    filled += n
  }
  let _ = f.close()
  Ok(Bytes::from_fixedarray(buf, len=filled))
}

///|
/// Writes `data` to `path`, creating or truncating it.
pub fn write_file(path : String, data : Bytes) -> Result[Unit, FsError] {
  let f = match File::open_write_or_create(path) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  let n = match f.write_all(data) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  if n != data.length() {
    return Err(Io(5, "write_file short write"))
  }
  let _ = f.flush()
  f.close()
}
