// SPDX-License-Identifier: Apache-2.0
// FFI surface to the net shims. Return convention: negative values
// are -errno; buffers are borrowed.

///|
#borrow(host)
pub extern "C" fn net_connect(
  host : Bytes,
  host_len : Int32,
  port : Int32,
) -> Int32 = "mf_net_connect"

///|
#borrow(host)
pub extern "C" fn net_bind_listen(
  host : Bytes,
  host_len : Int32,
  port : Int32,
) -> Int32 = "mf_net_bind_listen"

///|
pub extern "C" fn net_getsockport(fd : Int32) -> Int32 = "mf_net_getsockport"

///|
pub extern "C" fn net_accept(fd : Int32) -> Int32 = "mf_net_accept"

///|
#borrow(buf)
pub extern "C" fn net_send(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "mf_net_send"

///|
#borrow(buf)
pub extern "C" fn net_recv(
  fd : Int32,
  buf : FixedArray[Byte],
  len : Int32,
) -> Int32 = "mf_net_recv"

///|
pub extern "C" fn net_close(fd : Int32) -> Int32 = "mf_net_close"

///|
#borrow(pair)
pub extern "C" fn net_socketpair(pair : FixedArray[Int32]) -> Int32 = "mf_net_socketpair"

///|
pub extern "C" fn net_set_recv_timeout(fd : Int32, ms : Int32) -> Int32 = "mf_net_set_recv_timeout"

///|
pub extern "C" fn net_accept_timeout(fd : Int32, ms : Int32) -> Int32 = "mf_net_accept_timeout"

///|
pub extern "C" fn net_set_nonblocking(fd : Int32, enabled : Int32) -> Int32 = "mf_net_set_nonblocking"

///|
#borrow(buf)
pub extern "C" fn net_recv_some(
  fd : Int32,
  buf : FixedArray[Byte],
  len : Int32,
) -> Int32 = "mf_net_recv_some"

///|
#borrow(fds, ready)
extern "C" fn net_poll_writable(
  fds : FixedArray[Int32],
  count : Int32,
  timeout_ms : Int32,
  ready : FixedArray[Int32],
) -> Int32 = "mf_net_poll_writable"

///|
#borrow(fds, ready)
extern "C" fn net_poll_readable(
  fds : FixedArray[Int32],
  count : Int32,
  timeout_ms : Int32,
  ready : FixedArray[Int32],
) -> Int32 = "mf_net_poll_readable"

///|
#borrow(buf)
pub extern "C" fn net_send_some(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "mf_net_send_some"

///|
/// The text of an errno, for error messages.
#borrow(buf)
pub extern "C" fn net_strerror(
  code : Int32,
  buf : FixedArray[Byte],
  len : Int32,
) -> Unit = "mf_net_strerror"
