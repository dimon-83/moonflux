// SPDX-License-Identifier: Apache-2.0
// Authentication at the node (P12): the credential table, and the gate
// every connection passes through before it is served.
//
// Two decisions worth stating:
//
//   * **off by default, and loud about it.** A node with no `auth.json`
//     behaves exactly as it did before this milestone — every existing
//     deployment and gate keeps working — and says so in its startup
//     log. Security that turns itself on would break someone's
//     automation; security that turns itself on *silently* would be
//     worse.
//   * **the gate answers, the dispatcher decides.** Identifying a
//     connection is one thing; whether that identity may run a command
//     is another, and it lives in `core/auth`'s table, not here.

///|
/// The credential table as it is stored: `{ "credentials": [ { "name",
/// "token", "role" } ] }`.
struct AuthConfig {
  credentials : Array[@auth.Credential]
}

///|
fn auth_path(data_dir : String) -> String {
  "\{data_dir}/auth.json"
}

///|
fn AuthConfig::load(data_dir : String) -> AuthConfig {
  let path = auth_path(data_dir)
  match @fs.exists(path) {
    Ok(true) => ()
    _ => return AuthConfig::{ credentials: [] }
  }
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => fail("read \{path}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => fail("corrupt \{path}: \{e}")
  }
  let entries = match json.value("credentials") {
    Some(Array(entries)) => entries
    _ => fail("corrupt \{path}: missing credentials array")
  }
  let credentials : Array[@auth.Credential] = []
  for entry in entries {
    let name = match entry.value("name") {
      Some(String(name)) => name
      _ => fail("corrupt \{path}: a credential has no name")
    }
    let token = match entry.value("token") {
      Some(String(token)) => token
      _ => fail("corrupt \{path}: credential \{name} has no token")
    }
    if token.length() < 8 {
      fail(
        "\{path}: credential \{name} has a token shorter than 8 characters; short secrets are not secrets",
      )
    }
    let role = match entry.value("role") {
      Some(String(role)) =>
        match @auth.parse_role(role) {
          Ok(role) => role
          Err(e) => fail("\{path}: credential \{name}: \{e}")
        }
      _ => fail("corrupt \{path}: credential \{name} has no role")
    }
    credentials.push(@auth.Credential::{ name, token, role })
  }
  AuthConfig::{ credentials, }
}

///|
/// Whether this node requires credentials at all.
fn AuthConfig::required(self : AuthConfig) -> Bool {
  self.credentials.length() > 0
}

///|
/// Identifies a presented token, or None.
fn AuthConfig::identify(self : AuthConfig, token : String) -> @auth.Identity? {
  @auth.authenticate(self.credentials, token)
}

///|
/// Announces the mode at startup. A node running without authentication
/// must say so — an operator should never have to guess which mode
/// their cluster is in.
fn announce_auth_mode(data_dir : String, config : AuthConfig) -> Unit {
  if config.required() {
    note(
      "authentication ENABLED (\{config.credentials.length()} credential(s) from \{auth_path(data_dir)})",
    )
  } else {
    note(
      "authentication DISABLED (no credentials in \{auth_path(data_dir)}): every connection is trusted — intended for local development",
    )
  }
}

///|
/// The per-connection gate: what the transport handshake needs to know
/// about this node's authentication, plus the identity it resolved.
struct AuthGate {
  config : AuthConfig
}

///|
/// The answer to an AUTH attempt, as the transport needs it.
enum AuthOutcome {
  /// The credential was accepted; the identity rides with the session.
  Accepted(@auth.Identity)
  /// No credential configured on this node: everything is trusted (and
  /// the identity is a local one, so permission checks still run).
  NotRequired
  /// Required and missing or wrong.
  Rejected(String)
}

///|
/// Validates a presented token. Called by the transport layer's
/// handshake, which is the only place that knows whether a connection
/// has authenticated yet.
fn AuthGate::present(self : AuthGate, token : String) -> AuthOutcome {
  if !self.config.required() {
    return NotRequired
  }
  match self.config.identify(token) {
    Some(identity) => Accepted(identity)
    None => Rejected("unknown credential")
  }
}
