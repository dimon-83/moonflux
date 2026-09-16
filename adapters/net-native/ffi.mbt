// SPDX-License-Identifier: Apache-2.0
// FFI surface to the net shims. Return convention: negative values
// are -errno; buffers are borrowed.

///|
#borrow(host)
pub extern "C" fn net_connect(host : Bytes, host_len : Int, port : Int) -> Int = "mf_net_connect"

///|
#borrow(host)
pub extern "C" fn net_bind_listen(
  host : Bytes,
  host_len : Int,
  port : Int,
) -> Int = "mf_net_bind_listen"

///|
pub extern "C" fn net_getsockport(fd : Int) -> Int = "mf_net_getsockport"

///|
pub extern "C" fn net_accept(fd : Int) -> Int = "mf_net_accept"

///|
#borrow(buf)
pub extern "C" fn net_send(fd : Int, buf : Bytes, len : Int) -> Int = "mf_net_send"

///|
#borrow(buf)
pub extern "C" fn net_recv(fd : Int, buf : FixedArray[Byte], len : Int) -> Int = "mf_net_recv"

///|
pub extern "C" fn net_close(fd : Int) -> Int = "mf_net_close"

///|
#borrow(pair)
pub extern "C" fn net_socketpair(pair : FixedArray[Int]) -> Int = "mf_net_socketpair"

///|
pub extern "C" fn net_set_recv_timeout(fd : Int, ms : Int) -> Int = "mf_net_set_recv_timeout"

///|
pub extern "C" fn net_accept_timeout(fd : Int, ms : Int) -> Int = "mf_net_accept_timeout"
