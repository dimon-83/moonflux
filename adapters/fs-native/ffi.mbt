// FFI surface to the fs shims. Bytes/FixedArray[Byte] map to
// uint8_t*; every borrowed pointer parameter is annotated #borrow.

///|
#borrow(path)
pub extern "C" fn fs_open(path : Bytes, len : Int, mode : Int) -> Int = "mf_fs_open"

///|
#borrow(buf)
pub extern "C" fn fs_pread(
  fd : Int,
  buf : FixedArray[Byte],
  len : Int,
  offset : Int,
) -> Int = "mf_fs_pread"

///|
#borrow(buf)
pub extern "C" fn fs_write(fd : Int, buf : Bytes, len : Int) -> Int = "mf_fs_write"

///|
pub extern "C" fn fs_close(fd : Int) -> Int = "mf_fs_close"

///|
pub extern "C" fn fs_filesize(fd : Int) -> Int = "mf_fs_filesize"

///|
pub extern "C" fn fs_flush(fd : Int) -> Int = "mf_fs_flush"

///|
#borrow(path)
pub extern "C" fn fs_mkdirs(path : Bytes, len : Int) -> Int = "mf_fs_mkdirs"

///|
#borrow(path)
pub extern "C" fn fs_remove(path : Bytes, len : Int) -> Int = "mf_fs_remove"

///|
#borrow(path)
pub extern "C" fn fs_exists(path : Bytes, len : Int) -> Int = "mf_fs_exists"

///|
pub extern "C" fn fs_truncate(fd : Int, new_size : Int) -> Int = "mf_fs_truncate"
