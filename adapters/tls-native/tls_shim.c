// SPDX-License-Identifier: Apache-2.0
// adapters/tls-native shim: OpenSSL through dlopen.
//
// Same posture as the wasmtime host (decision 14): the library is
// resolved at runtime, so there is no link-time dependency and a machine
// without libssl loses *only* TLS — everything else still runs.
// MOONFLUX_TLS_LIB overrides the path (useful for a non-standard
// install, or for pointing the gate at a specific build).
//
// The surface is deliberately small: the handful of calls a
// non-blocking server and client actually need, with `SSL_get_error`
// translated into a value the caller can act on (done / want-read /
// want-write / error) rather than an errno soup.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;

// SSL_get_error results we care about (values are stable ABI).
#define MF_TLS_ERROR_NONE 0
#define MF_TLS_ERROR_SSL 1
#define MF_TLS_ERROR_WANT_READ 2
#define MF_TLS_ERROR_WANT_WRITE 3
#define MF_TLS_ERROR_SYSCALL 5

// SSL_VERIFY_* flags (stable ABI).
#define MF_TLS_VERIFY_NONE 0x00
#define MF_TLS_VERIFY_PEER 0x01
#define MF_TLS_VERIFY_FAIL_IF_NO_PEER_CERT 0x02

static void *ssl_handle = NULL;
static void *crypto_handle = NULL;

static SSL_CTX *(*p_SSL_CTX_new)(const void *method);
static void (*p_SSL_CTX_free)(SSL_CTX *);
static int (*p_SSL_CTX_use_certificate_chain_file)(SSL_CTX *, const char *);
static int (*p_SSL_CTX_use_PrivateKey_file)(SSL_CTX *, const char *, int);
static int (*p_SSL_CTX_load_verify_locations)(SSL_CTX *, const char *, const char *);
static void (*p_SSL_CTX_set_verify)(SSL_CTX *, int, void *);
static const void *(*p_TLS_method)(void);
static const void *(*p_TLS_server_method)(void);
static const void *(*p_TLS_client_method)(void);
static SSL *(*p_SSL_new)(SSL_CTX *);
static void (*p_SSL_free)(SSL *);
static int (*p_SSL_set_fd)(SSL *, int);
static int (*p_SSL_accept)(SSL *);
static int (*p_SSL_connect)(SSL *);
static int (*p_SSL_read)(SSL *, void *, int);
static int (*p_SSL_write)(SSL *, const void *, int);
static int (*p_SSL_get_error)(const SSL *, int);
static int (*p_SSL_pending)(const SSL *);
static int (*p_SSL_shutdown)(SSL *);
static unsigned long (*p_ERR_get_error)(void);
static void (*p_ERR_error_string_n)(unsigned long, char *, size_t);
static int (*p_OPENSSL_init_ssl)(uint64_t, const void *);
static int (*p_SSL_set1_host)(SSL *, const char *);
static long (*p_SSL_get_verify_result)(const SSL *);

static const char *const k_candidates[] = {
    "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
    "/opt/homebrew/lib/libssl.3.dylib",
    "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
    "/usr/local/lib/libssl.3.dylib",
    "libssl.3.dylib",
    "libssl.so.3",
    "libssl.so",
    NULL,
};

static const char *const k_crypto_candidates[] = {
    "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
    "/opt/homebrew/lib/libcrypto.3.dylib",
    "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib",
    "/usr/local/lib/libcrypto.3.dylib",
    "libcrypto.3.dylib",
    "libcrypto.so.3",
    "libcrypto.so",
    NULL,
};

// Reports the last failure to the caller in text. Kept as a shim-level
// buffer so the MoonBit side never has to know about dlopen.
static char last_error[512] = "";

static void set_error(const char *text) {
  snprintf(last_error, sizeof(last_error), "%s", text);
  last_error[sizeof(last_error) - 1] = '\0';
}

// Like set_ssl_error, but names the file the shim was given — a path
// that never reached C intact looks exactly like a missing file from
// here, and the difference is worth seeing without a debugger.
static void set_ssl_error2(const char *prefix, const char *path) {
  unsigned long code = p_ERR_get_error ? p_ERR_get_error() : 0;
  char detail[256] = "";
  if (code != 0 && p_ERR_error_string_n) {
    p_ERR_error_string_n(code, detail, sizeof(detail));
  }
  snprintf(last_error, sizeof(last_error), "%s [%s]: %s", prefix,
           path == NULL ? "(null)" : path, detail);
  last_error[sizeof(last_error) - 1] = '\0';
}

static void set_ssl_error(const char *prefix) {
  unsigned long code = p_ERR_get_error ? p_ERR_get_error() : 0;
  char detail[256] = "";
  if (code != 0 && p_ERR_error_string_n) {
    p_ERR_error_string_n(code, detail, sizeof(detail));
  }
  snprintf(last_error, sizeof(last_error), "%s: %s", prefix, detail);
  last_error[sizeof(last_error) - 1] = '\0';
}

/// Loads the library and resolves every symbol. Returns 1 on success,
/// 0 when TLS is simply unavailable on this machine (a normal state, not
/// an error: the caller decides what to do about it).
int32_t mf_tls_init(void) {
  if (ssl_handle != NULL) {
    return 1;
  }
  const char *override = getenv("MOONFLUX_TLS_LIB");
  if (override != NULL && override[0] != '\0') {
    ssl_handle = dlopen(override, RTLD_NOW | RTLD_LOCAL);
    if (ssl_handle == NULL) {
      set_error(dlerror());
      return 0;
    }
  } else {
    for (int i = 0; k_candidates[i] != NULL && ssl_handle == NULL; i++) {
      ssl_handle = dlopen(k_candidates[i], RTLD_NOW | RTLD_LOCAL);
    }
  }
  if (ssl_handle == NULL) {
    set_error("no libssl found (set MOONFLUX_TLS_LIB to point at one)");
    return 0;
  }
  for (int i = 0; k_crypto_candidates[i] != NULL && crypto_handle == NULL; i++) {
    crypto_handle = dlopen(k_crypto_candidates[i], RTLD_NOW | RTLD_LOCAL);
  }
  if (crypto_handle == NULL) {
    set_error("libssl loaded but libcrypto was not found");
    return 0;
  }

#define RESOLVE(var, handle, name)                       \
  do {                                                   \
    *(void **)(&var) = dlsym(handle, name);              \
    if (var == NULL) {                                   \
      set_error("missing symbol " name);                 \
      return 0;                                          \
    }                                                    \
  } while (0)

  RESOLVE(p_SSL_CTX_new, ssl_handle, "SSL_CTX_new");
  RESOLVE(p_SSL_CTX_free, ssl_handle, "SSL_CTX_free");
  RESOLVE(p_SSL_CTX_use_certificate_chain_file, ssl_handle,
          "SSL_CTX_use_certificate_chain_file");
  RESOLVE(p_SSL_CTX_use_PrivateKey_file, ssl_handle, "SSL_CTX_use_PrivateKey_file");
  RESOLVE(p_SSL_CTX_load_verify_locations, ssl_handle,
          "SSL_CTX_load_verify_locations");
  RESOLVE(p_SSL_CTX_set_verify, ssl_handle, "SSL_CTX_set_verify");
  RESOLVE(p_TLS_method, ssl_handle, "TLS_method");
  RESOLVE(p_TLS_server_method, ssl_handle, "TLS_server_method");
  RESOLVE(p_TLS_client_method, ssl_handle, "TLS_client_method");
  RESOLVE(p_SSL_new, ssl_handle, "SSL_new");
  RESOLVE(p_SSL_free, ssl_handle, "SSL_free");
  RESOLVE(p_SSL_set_fd, ssl_handle, "SSL_set_fd");
  RESOLVE(p_SSL_accept, ssl_handle, "SSL_accept");
  RESOLVE(p_SSL_connect, ssl_handle, "SSL_connect");
  RESOLVE(p_SSL_read, ssl_handle, "SSL_read");
  RESOLVE(p_SSL_write, ssl_handle, "SSL_write");
  RESOLVE(p_SSL_get_error, ssl_handle, "SSL_get_error");
  RESOLVE(p_SSL_pending, ssl_handle, "SSL_pending");
  RESOLVE(p_SSL_shutdown, ssl_handle, "SSL_shutdown");
  RESOLVE(p_ERR_get_error, crypto_handle, "ERR_get_error");
  RESOLVE(p_ERR_error_string_n, crypto_handle, "ERR_error_string_n");
  // optional: older builds may not export it, and it is only a nicety
  *(void **)(&p_OPENSSL_init_ssl) = dlsym(ssl_handle, "OPENSSL_init_ssl");
  *(void **)(&p_SSL_set1_host) = dlsym(ssl_handle, "SSL_set1_host");
  *(void **)(&p_SSL_get_verify_result) = dlsym(ssl_handle, "SSL_get_verify_result");
#undef RESOLVE

  set_error("");
  return 1;
}

/// The shim's last message (available even when init failed).
void mf_tls_last_error(uint8_t *buf, int32_t len) {
  if (len <= 0) {
    return;
  }
  int n = (int)strlen(last_error);
  if (n >= len) {
    n = len - 1;
  }
  memcpy(buf, last_error, (size_t)n);
  buf[n] = 0;
}

/// A server context. `verify_client` != 0 requires a client certificate
/// signed by `ca` (mutual TLS: what node-to-node traffic uses).
intptr_t mf_tls_server_ctx(const uint8_t *cert, const uint8_t *key,
                           const uint8_t *ca, int32_t verify_client) {
  // Arguments are NUL-terminated paths, not length-carrying buffers: the
  // OpenSSL file APIs take C strings, and a length parameter nobody
  // reads is a parameter that can be passed in the wrong order (which is
  // exactly what happened: the C side took six arguments, the MoonBit
  // side declared four, and the shim read a length as a pointer).
  SSL_CTX *ctx = p_SSL_CTX_new(p_TLS_server_method());
  if (ctx == NULL) {
    set_error("SSL_CTX_new failed");
    return 0;
  }
  if (p_SSL_CTX_use_certificate_chain_file(ctx, (const char *)cert) != 1) {
    set_ssl_error2("cannot load the certificate", (const char *)cert);
    p_SSL_CTX_free(ctx);
    return 0;
  }
  if (p_SSL_CTX_use_PrivateKey_file(ctx, (const char *)key, 1 /* PEM */) != 1) {
    set_ssl_error2("cannot load the private key", (const char *)key);
    p_SSL_CTX_free(ctx);
    return 0;
  }
  if (ca != NULL && ca[0] != '\0') {
    if (p_SSL_CTX_load_verify_locations(ctx, (const char *)ca, NULL) != 1) {
      set_ssl_error("cannot load the CA bundle");
      p_SSL_CTX_free(ctx);
      return 0;
    }
  }
  if (verify_client) {
    p_SSL_CTX_set_verify(ctx, MF_TLS_VERIFY_PEER | MF_TLS_VERIFY_FAIL_IF_NO_PEER_CERT,
                         NULL);
  }
  set_error("");
  return (intptr_t)ctx;
}

/// A client context. `ca` is the server's trust anchor; `cert`/`key` are
/// optional (a client certificate, for mutual TLS).
intptr_t mf_tls_client_ctx(const uint8_t *ca, const uint8_t *cert,
                           const uint8_t *key) {
  SSL_CTX *ctx = p_SSL_CTX_new(p_TLS_client_method());
  if (ctx == NULL) {
    set_error("SSL_CTX_new failed");
    return 0;
  }
  if (ca != NULL && ca[0] != '\0') {
    if (p_SSL_CTX_load_verify_locations(ctx, (const char *)ca, NULL) != 1) {
      set_ssl_error("cannot load the CA bundle");
      p_SSL_CTX_free(ctx);
      return 0;
    }
  }
  // **Verify by default.** OpenSSL's client default is SSL_VERIFY_NONE:
  // load a CA bundle without this and the client accepts any certificate
  // the server offers — the handshake succeeds, the CA is decoration,
  // and the failure is silent. Loading a CA and not asking for
  // verification is worse than not doing TLS at all, because it looks
  // like it worked.
  p_SSL_CTX_set_verify(ctx, MF_TLS_VERIFY_PEER, NULL);
  if (cert != NULL && cert[0] != '\0' && key != NULL && key[0] != '\0') {
    if (p_SSL_CTX_use_certificate_chain_file(ctx, (const char *)cert) != 1) {
      set_ssl_error("cannot load the client certificate");
      p_SSL_CTX_free(ctx);
      return 0;
    }
    if (p_SSL_CTX_use_PrivateKey_file(ctx, (const char *)key, 1) != 1) {
      set_ssl_error("cannot load the client key");
      p_SSL_CTX_free(ctx);
      return 0;
    }
  }
  set_error("");
  return (intptr_t)ctx;
}

void mf_tls_ctx_free(intptr_t ctx) {
  if (ctx != 0) {
    p_SSL_CTX_free((SSL_CTX *)ctx);
  }
}

/// A session over an already-connected fd.
intptr_t mf_tls_new(intptr_t ctx, int32_t fd) {
  SSL *ssl = p_SSL_new((SSL_CTX *)ctx);
  if (ssl == NULL) {
    set_error("SSL_new failed");
    return 0;
  }
  if (p_SSL_set_fd(ssl, (int)fd) != 1) {
    set_ssl_error("SSL_set_fd failed");
    p_SSL_free(ssl);
    return 0;
  }
  return (intptr_t)ssl;
}

/// Pins the host name the server certificate must match. Called by the
/// client before the handshake: a certificate that verifies but names
/// somebody else is exactly the mistake this prevents.
void mf_tls_set_host(intptr_t ssl, const uint8_t *host) {
  if (p_SSL_set1_host != NULL && host != NULL && host[0] != '\0') {
    p_SSL_set1_host((SSL *)ssl, (const char *)host);
  }
}

/// The verification result of the last handshake (0 = fine). Reported
/// because a failed verification leaves *this* code set while the error
/// queue may say nothing useful at all.
long mf_tls_verify_result(intptr_t ssl) {
  if (p_SSL_get_verify_result == NULL) {
    return 0;
  }
  return p_SSL_get_verify_result((SSL *)ssl);
}

/// Drives the handshake. Returns 1 done, 0 wants more (the caller polls
/// and calls again: the socket is non-blocking), -1 failed.
// Tri-state, because the direction matters: the caller must poll the
// socket for *readability* or *writability*, and guessing wrong stalls
// both peers forever (which is exactly what happened when this returned
// a bare "pending" and the shim re-derived the direction with a second,
// invalid SSL_get_error call).
#define MF_TLS_WANT_READ_CODE 0
#define MF_TLS_WANT_WRITE_CODE 2

int32_t mf_tls_handshake(intptr_t ssl, int32_t server) {
  int rc = server ? p_SSL_accept((SSL *)ssl) : p_SSL_connect((SSL *)ssl);
  if (rc == 1) {
    return 1;
  }
  int err = p_SSL_get_error((SSL *)ssl, rc);
  if (err == MF_TLS_ERROR_WANT_READ) {
    return MF_TLS_WANT_READ_CODE;
  }
  if (err == MF_TLS_ERROR_WANT_WRITE) {
    return MF_TLS_WANT_WRITE_CODE;
  }
  long verify = mf_tls_verify_result(ssl);
  set_ssl_error(server ? "TLS accept failed" : "TLS connect failed");
  if (verify != 0) {
    char detail[512];
    snprintf(detail, sizeof(detail), "%s (certificate verification failed, code %ld)",
             last_error, verify);
    snprintf(last_error, sizeof(last_error), "%s", detail);
  }
  return -1;
}

/// Reads up to `len` bytes. >0 = bytes, 0 = the peer closed cleanly,
/// -1 = wants more (poll and retry), -2 = error.
int32_t mf_tls_read(intptr_t ssl, uint8_t *buf, int32_t len) {
  if (len <= 0) {
    return 0;
  }
  int rc = p_SSL_read((SSL *)ssl, buf, (int)len);
  if (rc > 0) {
    return rc;
  }
  int err = p_SSL_get_error((SSL *)ssl, rc);
  if (err == MF_TLS_ERROR_WANT_READ) {
    return -1;
  }
  if (err == MF_TLS_ERROR_WANT_WRITE) {
    return -3;
  }
  if (err == MF_TLS_ERROR_NONE || (err == MF_TLS_ERROR_SYSCALL && rc == 0)) {
    return 0;
  }
  set_ssl_error("TLS read failed");
  return -2;
}

/// Writes up to `len` bytes. >0 = written, -1 = wants more, -2 = error.
int32_t mf_tls_write(intptr_t ssl, const uint8_t *buf, int32_t len) {
  if (len <= 0) {
    return 0;
  }
  int rc = p_SSL_write((SSL *)ssl, buf, (int)len);
  if (rc > 0) {
    return rc;
  }
  int err = p_SSL_get_error((SSL *)ssl, rc);
  if (err == MF_TLS_ERROR_WANT_READ) {
    return -1;
  }
  if (err == MF_TLS_ERROR_WANT_WRITE) {
    return -3;
  }
  set_ssl_error("TLS write failed");
  return -2;
}

/// Bytes already decrypted and buffered inside the session. The poll
/// loop must treat these as readable: the socket may not be, while the
/// session still has data to hand over.
int32_t mf_tls_pending(intptr_t ssl) {
  return p_SSL_pending((SSL *)ssl);
}

void mf_tls_free(intptr_t ssl) {
  if (ssl != 0) {
    p_SSL_shutdown((SSL *)ssl);
    p_SSL_free((SSL *)ssl);
  }
}
