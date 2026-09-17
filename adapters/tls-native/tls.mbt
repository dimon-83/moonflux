// SPDX-License-Identifier: Apache-2.0
// adapters/tls-native: TLS sessions over the plain transport (P12).
//
// The layering, stated because it is the whole design:
//
//   * `net-native` owns *sockets*: accept, connect, poll, close.
//   * this package owns *TLS sessions* over an accepted or dialled
//     socket, and knows nothing about the protocol above it.
//   * everything above (the hub, the replication link, the client
//     kernel's `Conn`) sees a `@net.Stream` — an interface of function
//     fields, the same shape the client kernel already used for its own
//     transport injection. TLS and plaintext are two constructors of
//     that interface, not two code paths.
//
// The library is loaded at runtime (see the shim): no link-time
// dependency, and a machine without libssl loses only TLS.

///|
/// A path as a NUL-terminated byte string, which is what the C side
/// expects. Built here so every call site passes the same shape.
fn cstring(text : String) -> Bytes {
  let bytes = @utf8.encode(text[0:text.length()])
  buffer_for(bytes)
}

///|
fn buffer_for(bytes : Bytes) -> Bytes {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(bytes[0:bytes.length()])
  out.write_byte(b'\x00')
  out.to_bytes()
}

///|
/// The shim's error text, or "" when it has nothing to say.
fn shim_error() -> String {
  let buf : FixedArray[Byte] = FixedArray::make(512, b'\x00')
  tls_last_error(buf, buf.length())
  let mut end = 0
  while end < buf.length() && buf[end] != b'\x00' {
    end = end + 1
  }
  @utf8.decode_lossy(Bytes::from_array(buf[:end]))
}

///|
/// Whether TLS is available on this machine at all. A `false` here is a
/// *state*, not a failure: the caller reports it and carries on without
/// TLS (the same "capability may be absent" stance the wasmtime host
/// takes for operators).
pub fn available() -> Bool {
  tls_init() == 1
}

///|
/// The reason TLS is unavailable (empty when it is available).
pub fn unavailable_reason() -> String {
  if available() {
    ""
  } else {
    shim_error()
  }
}

///|
/// A TLS session: the SSL handle plus the socket it rides on. Kept as a
/// handle (not a struct of closures) because the handshake is driven in
/// steps — a non-blocking server cannot afford to block the loop on a
/// peer that has not finished saying hello.
pub struct TlsSession {
  /// The SSL handle. **Int64, not Int**: MoonBit's `Int` is 32-bit, and
  /// squeezing a pointer through it truncates it — which is a crash, not
  /// a warning (the first cut of this adapter did exactly that).
  ssl : Int64
  fd : Int
}

///|
/// True when the handle is live.
pub fn TlsSession::is_live(self : TlsSession) -> Bool {
  self.ssl != 0L
}

///|
/// The socket under the session, for polling.
pub fn TlsSession::fd(self : TlsSession) -> Int {
  self.fd
}

///|
/// A server context: the certificate to present, and optionally the CA a
/// client certificate must chain to (`require_client` = mutual TLS, which
/// is what node-to-node traffic uses).
pub struct TlsContext {
  /// The SSL_CTX handle; Int64 for the same reason as `TlsSession.ssl`.
  ctx : Int64
}

///|
pub fn server_context(
  cert_path : String,
  key_path : String,
  ca_path : String,
  require_client : Bool,
) -> Result[TlsContext, String] {
  if !available() {
    return Err("TLS is unavailable: \{unavailable_reason()}")
  }
  let ctx = tls_server_ctx(
    cstring(cert_path),
    cstring(key_path),
    cstring(ca_path),
    if require_client {
      1
    } else {
      0
    },
  )
  if ctx == 0L {
    return Err("cannot create a TLS server context: \{shim_error()}")
  }
  Ok(TlsContext::{ ctx, })
}

///|
pub fn client_context(
  ca_path : String,
  cert_path : String?,
  key_path : String?,
) -> Result[TlsContext, String] {
  if !available() {
    return Err("TLS is unavailable: \{unavailable_reason()}")
  }
  let (cert, key) = match (cert_path, key_path) {
    (Some(cert), Some(key)) => (cert, key)
    _ => ("", "")
  }
  let ctx = tls_client_ctx(cstring(ca_path), cstring(cert), cstring(key))
  if ctx == 0L {
    return Err("cannot create a TLS client context: \{shim_error()}")
  }
  Ok(TlsContext::{ ctx, })
}

///|
pub fn TlsContext::free(self : TlsContext) -> Unit {
  tls_ctx_free(self.ctx)
}

///|
/// Attaches a session to a connected socket. The socket must be
/// non-blocking: this package never waits, it reports "wants more" and
/// lets its caller poll (`@net` has the poll).
pub fn TlsContext::attach(
  self : TlsContext,
  fd : Int,
) -> Result[TlsSession, String] {
  let ssl = tls_new(self.ctx, fd)
  if ssl == 0L {
    return Err("cannot create a TLS session: \{shim_error()}")
  }
  Ok(TlsSession::{ ssl, fd })
}

///|
/// One step of the handshake. `Pending` means "poll and call again" —
/// the caller decides how to wait, because only it knows what else it
/// has to serve in the meantime.
pub(all) enum HandshakeStep {
  Done
  /// whether the session is waiting for the socket to become writable
  Pending(Bool)
}

///|
/// Drives one step of a server-side handshake.
pub fn TlsSession::accept(self : TlsSession) -> Result[HandshakeStep, String] {
  match tls_handshake(self.ssl, 1) {
    1 => Ok(Done)
    0 => Ok(Pending(false))
    2 => Ok(Pending(true))
    _ => Err("TLS handshake failed: \{shim_error()}")
  }
}

///|
/// Pins the host name the server certificate must match (P12). Set by
/// the client before the handshake: verification that ignores the name
/// accepts any certificate the CA ever signed.
pub fn TlsSession::set_host(self : TlsSession, host : String) -> Unit {
  if self.ssl != 0L {
    tls_set_host(self.ssl, cstring(host))
  }
}

///|
/// Drives one step of a client-side handshake.
pub fn TlsSession::connect(self : TlsSession) -> Result[HandshakeStep, String] {
  match tls_handshake(self.ssl, 0) {
    1 => Ok(Done)
    0 => Ok(Pending(false))
    2 => Ok(Pending(true))
    _ => Err("TLS handshake failed: \{shim_error()}")
  }
}

///|
/// Bytes the session has decrypted and buffered. A poll loop that only
/// watches the socket would sleep through them.
pub fn TlsSession::pending(self : TlsSession) -> Int {
  tls_pending(self.ssl)
}

///|
/// Reads into `buf`. `None` means "wants more" (poll, then retry); an
/// empty result means the peer closed cleanly.
pub fn TlsSession::read_some(
  self : TlsSession,
  buf : FixedArray[Byte],
  len : Int,
) -> Result[Int?, String] {
  let rc = tls_read(self.ssl, buf, len)
  if rc > 0 {
    return Ok(Some(rc))
  }
  if rc == 0 {
    return Ok(Some(0))
  }
  if rc == -1 {
    return Ok(None)
  }
  if rc == -3 {
    // the session wants the socket *writable* mid-read (a renegotiation
    // flight): a plain "would block" is the closest the stream interface
    // can say, and the poller retries
    return Ok(None)
  }
  Err("TLS read failed: \{shim_error()}")
}

///|
/// Writes from `bytes`. `None` means "wants more" (poll, then retry).
pub fn TlsSession::write_some(
  self : TlsSession,
  bytes : Bytes,
) -> Result[Int?, String] {
  let rc = tls_write(self.ssl, bytes, bytes.length())
  if rc > 0 {
    return Ok(Some(rc))
  }
  if rc == 0 {
    return Ok(Some(0))
  }
  if rc == -1 || rc == -3 {
    return Ok(None)
  }
  Err("TLS write failed: \{shim_error()}")
}

///|
/// Closes the session (and, with it, the socket underneath).
pub fn TlsSession::close(self : TlsSession) -> Unit {
  if self.ssl != 0L {
    tls_free(self.ssl)
  }
}

// ---------------------------------------------------------------------
// The shim, as externs. Names match tls_shim.c exactly.

///|
extern "C" fn tls_init() -> Int = "mf_tls_init"

///|
#borrow(host)
extern "C" fn tls_set_host(ssl : Int64, host : Bytes) -> Unit = "mf_tls_set_host"

///|
extern "C" fn tls_verify_result(ssl : Int64) -> Int64 = "mf_tls_verify_result"

///|
#borrow(buf)
extern "C" fn tls_last_error(buf : FixedArray[Byte], len : Int) -> Unit = "mf_tls_last_error"

///|
#borrow(cert, key, ca)
extern "C" fn tls_server_ctx(
  cert : Bytes,
  key : Bytes,
  ca : Bytes,
  require_client : Int,
) -> Int64 = "mf_tls_server_ctx"

///|
#borrow(ca, cert, key)
extern "C" fn tls_client_ctx(ca : Bytes, cert : Bytes, key : Bytes) -> Int64 = "mf_tls_client_ctx"

///|
extern "C" fn tls_ctx_free(ctx : Int64) -> Unit = "mf_tls_ctx_free"

///|
extern "C" fn tls_new(ctx : Int64, fd : Int) -> Int64 = "mf_tls_new"

///|
extern "C" fn tls_handshake(ssl : Int64, server : Int) -> Int = "mf_tls_handshake"

///|
#borrow(buf)
extern "C" fn tls_read(ssl : Int64, buf : FixedArray[Byte], len : Int) -> Int = "mf_tls_read"

///|
#borrow(buf)
extern "C" fn tls_write(ssl : Int64, buf : Bytes, len : Int) -> Int = "mf_tls_write"

///|
extern "C" fn tls_pending(ssl : Int64) -> Int = "mf_tls_pending"

///|
extern "C" fn tls_free(ssl : Int64) -> Unit = "mf_tls_free"
