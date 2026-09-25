// SPDX-License-Identifier: Apache-2.0
// apps/cli/rotation.mbt (P24): rotation without restart.
//
// Certificates expire and credentials change; neither should cost a
// restart of a process that is mid-transaction or mid-election. The
// mechanism is **mtime watching**, not a signal: the loop already owns
// a one-second housekeeping beat, a stat() costs microseconds, and
// "the file on disk changed" is exactly the trigger every secret
// rotation flow (cert-manager among them) produces — replacing the
// mounted file. It is also cross-platform and needs no shim.
//
// Two rules bind the reload:
//   * only NEW work sees the new material — connections already
//     established keep the certificate they were built on and the
//     identity they authenticated with, until they close naturally;
//   * a broken reload never takes the server down — a half-written or
//     corrupt document keeps the previous material serving and says so
//     on stderr. Startup is the place for fail-fast; a reload that
//     kills a live broker turns a config typo into an outage.

///|
/// The files a TLS listener was built from, and where their mtimes
/// stood when the context was last (re)built.
struct TlsWatch {
  cert : String
  key : String
  ca : String
  require_client : Bool
  mut cert_mtime : Int64
  mut key_mtime : Int64
  mut ca_mtime : Int64
}

///|
/// Everything this server may hot-reload: its TLS material (when it
/// runs TLS at all) and its credential table.
struct RotationWatch {
  tls : TlsWatch?
  auth : String?
  mut auth_mtime : Int64
}

///|
fn file_mtime_or_zero(path : String) -> Int64 {
  match @fs.mtime(path) {
    Ok(mtime) => mtime
    Err(_) => 0L // a vanished file reads as "no file", not a crash
  }
}

///|
/// Builds the watcher from the same inputs the listener was built
/// from, and records the mtimes it saw — so a file replaced BEFORE the
/// first check is still seen as new.
fn RotationWatch::new(tls : TlsWatch?, auth_path : String?) -> RotationWatch {
  let watch = match tls {
    None => tls
    Some(t) => {
      t.cert_mtime = file_mtime_or_zero(t.cert)
      t.key_mtime = file_mtime_or_zero(t.key)
      t.ca_mtime = file_mtime_or_zero(t.ca)
      Some(t)
    }
  }
  let mut auth_mtime = 0L
  match auth_path {
    Some(path) => auth_mtime = file_mtime_or_zero(path)
    None => ()
  }
  RotationWatch::{ tls: watch, auth: auth_path, auth_mtime }
}

///|
/// The TLS watch for a listener's flags (None for plaintext — nothing
/// to rotate), and the auth watch for the data dir.
fn RotationWatch::for_server(flags : Flags, data_dir : String) -> RotationWatch {
  let tls_watch = match flags.get("tls-cert") {
    None => None
    Some(cert) =>
      Some(TlsWatch::{
        cert,
        key: flags.require("tls-key"),
        ca: flags.get("tls-ca") |> unwrap_or(""),
        require_client: flags.get("tls-require-client") is Some(_),
        cert_mtime: 0L,
        key_mtime: 0L,
        ca_mtime: 0L,
      })
  }
  RotationWatch::new(tls_watch, Some(auth_path(data_dir)))
}

///|
/// Rebuilds the TLS context from the files on disk. An error here is a
/// warning, not a failure: the server keeps speaking with the material
/// it already has until the operator fixes the files.
fn TlsWatch::rebuild(self : TlsWatch, hub : ConnectionHub) -> Unit {
  match @tls.server_context(self.cert, self.key, self.ca, self.require_client) {
    Ok(context) => {
      hub.rotate_tls(context)
      self.cert_mtime = file_mtime_or_zero(self.cert)
      self.key_mtime = file_mtime_or_zero(self.key)
      self.ca_mtime = file_mtime_or_zero(self.ca)
      note(
        "TLS context rotated (certificate \{self.cert}\{if self.require_client {", peers must present a certificate" } else {""}}); existing connections are unaffected",
      )
    }
    Err(e) =>
      note(
        "warning: TLS rotation skipped, keeping the current certificate: \{e}",
      )
  }
}

///|
/// Re-reads the credential table into the gate. Existing connections
/// keep the identity they authenticated with; the next handshake
/// answers to the new table.
fn reload_credentials(gate : AuthGate) -> Unit {
  let data_dir = gate.data_dir
  match AuthConfig::load_result(data_dir) {
    Ok(config) => {
      gate.config = config
      let with_grants = config.credentials
        .filter(credential => credential.grants.length() > 0)
        .length()
      note(
        "credentials reloaded (\{config.credentials.length()} credential(s), \{with_grants} with per-topic grants); connections that already authenticated keep their identity",
      )
    }
    Err(e) =>
      note(
        "warning: credential reload skipped, keeping the current table: \{e}",
      )
  }
}

///|
/// The per-beat check: stat everything (microseconds), rebuild what
/// changed, keep what did not. Called on the loop's housekeeping
/// cadence — never per connection, and never with IO on the hot path
/// beyond the stat.
fn RotationWatch::check(
  self : RotationWatch,
  hub : ConnectionHub,
  gate : AuthGate,
) -> Unit {
  match self.tls {
    Some(t) => {
      let cert = file_mtime_or_zero(t.cert)
      let key = file_mtime_or_zero(t.key)
      let ca = file_mtime_or_zero(t.ca)
      if cert != t.cert_mtime || key != t.key_mtime || ca != t.ca_mtime {
        t.rebuild(hub)
      }
    }
    None => ()
  }
  match self.auth {
    Some(path) => {
      let mtime = file_mtime_or_zero(path)
      if mtime != self.auth_mtime {
        reload_credentials(gate)
        self.auth_mtime = file_mtime_or_zero(path)
      }
    }
    None => ()
  }
}
