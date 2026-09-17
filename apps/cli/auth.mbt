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

// ---------------------------------------------------------------------
// TLS (P12): the flags, and the transports they choose. Kept here, next
// to the credential plumbing, because both answer the same operator
// question — "how does this process talk to a peer" — and an operator
// sets them together.

///|
/// What a client needs to speak TLS: the trust anchor, and optionally a
/// client certificate (a node that must present one).
pub(all) struct TlsOptions {
  ca : String
  cert : String?
  key : String?
}

///|
/// Reads the TLS configuration, or None when this process speaks
/// plaintext. A client cannot "default to TLS": there is no trust anchor
/// to default to, and silently trusting everything would be worse than
/// being clear.
///
/// A flag wins and the environment fills the gap, which is the precedent
/// `--token`/`MOONFLUX_TOKEN` already set. It matters for callers with no
/// flag parser at all — a group member's coordinator calls, a node's
/// background pulls — where the alternative is threading a transport
/// parameter through a dozen functions that have no opinion about it.
fn tls_options(flags : Flags) -> TlsOptions? {
  tls_options_from(
    flag_or_env(flags, "tls-ca", "MOONFLUX_TLS_CA"),
    flag_or_env(flags, "tls-cert", "MOONFLUX_TLS_CERT"),
    flag_or_env(flags, "tls-key", "MOONFLUX_TLS_KEY"),
  )
}

///|
/// A flag if it was given, the environment otherwise.
fn flag_or_env(flags : Flags, flag : String, variable : String) -> String? {
  match flags.get(flag) {
    Some(value) => Some(value)
    None => @env.get_env_var(variable)
  }
}

///|
/// The environment's TLS configuration (same variables, no flags).
fn env_tls_options() -> TlsOptions? {
  tls_options_from(
    @env.get_env_var("MOONFLUX_TLS_CA"),
    @env.get_env_var("MOONFLUX_TLS_CERT"),
    @env.get_env_var("MOONFLUX_TLS_KEY"),
  )
}

///|
/// One place decides what a trust anchor plus an optional client
/// certificate mean, so every reader above agrees.
fn tls_options_from(ca : String?, cert : String?, key : String?) -> TlsOptions? {
  match ca {
    None => None
    Some(ca) => Some(TlsOptions::{ ca, cert, key })
  }
}

///|
/// How long a client waits for a TLS handshake before giving up.
const CLIENT_HANDSHAKE_TIMEOUT_MS : Int = 5000

///|
/// A consumer over either transport. One place decides, so `consume`
/// (plain, committed, partitioned, or a group member) cannot end up on a
/// different transport than its flags asked for.
fn connect_consumer_transport(
  host : String,
  port : Int,
  token : String?,
  tls : TlsOptions?,
) -> Result[@client.Consumer, @client.ClientError] {
  match tls {
    None => @native.connect_consumer_with(host, port, token)
    Some(options) => {
      let conn = match
        @native.tcp_tls(
          host,
          port,
          options.ca,
          options.cert,
          options.key,
          CLIENT_HANDSHAKE_TIMEOUT_MS,
        ) {
        Ok(conn) => conn
        Err(e) => return Err(@client.Transport(e))
      }
      @client.Consumer::from_conn_with(conn, token)
    }
  }
}

///|
/// A producer over either transport.
fn connect_producer_transport(
  host : String,
  port : Int,
  token : String?,
  tls : TlsOptions?,
) -> Result[@client.Producer, @client.ClientError] {
  match tls {
    None => @native.connect_producer_with(host, port, token)
    Some(options) => {
      let conn = match
        @native.tcp_tls(
          host,
          port,
          options.ca,
          options.cert,
          options.key,
          CLIENT_HANDSHAKE_TIMEOUT_MS,
        ) {
        Ok(conn) => conn
        Err(e) => return Err(@client.Transport(e))
      }
      @client.Producer::from_conn_with(conn, token)
    }
  }
}

// ---------------------------------------------------------------------
// Node-to-node (P12/T59). A node both serves and dials, so it has two
// sides to configure, and they must be configured *together*: a node
// that authenticates outbound but serves unauthenticated is a security
// face with a hole in it, and one that serves TLS but dials plaintext
// cannot reach its own peers.

///|
/// How this node talks to a peer: the credential it presents and the
/// transport it presents it over. One value threaded through every
/// outbound call (control plane, leader, peer), so "which of my calls
/// authenticate?" has one answer instead of a per-call-site answer.
pub(all) struct PeerLink {
  token : String?
  tls : TlsOptions?
}

///|
/// The link this process presents when it dials (`--token`, `--tls-ca`,
/// and optionally `--tls-cert`/`--tls-key` when peers require mutual
/// TLS). The same flags a client reads, because it is the same question:
/// a node is a client of its peers.
fn peer_link(flags : Flags) -> PeerLink {
  PeerLink::{ token: client_token(flags), tls: tls_options(flags) }
}

///|
/// How long a node's control/peer call may spend in the TLS handshake.
/// Shorter than the client's patience: a node has a tick to keep, and a
/// peer that cannot finish a handshake in this long is not going to.
const NODE_HANDSHAKE_TIMEOUT_MS : Int = 1000

///|
/// The listener side: `--tls-cert`/`--tls-key` turn TLS on for this
/// process's port, `--tls-ca` (with `--tls-require-client`) makes peers
/// present a certificate too. Returns None for plaintext — a listener
/// cannot "default to TLS" either, and an operator who forgot the flags
/// should get a loud plaintext server rather than a silent one.
fn tls_listener(flags : Flags) -> @tls.TlsContext? {
  let cert = match flags.get("tls-cert") {
    None => return None
    Some(cert) => cert
  }
  let key = flags.require("tls-key")
  let ca = flags.get("tls-ca") |> unwrap_or("")
  let require_client = flags.get("tls-require-client") is Some(_)
  match @tls.server_context(cert, key, ca, require_client) {
    Ok(context) => {
      note(
        "TLS ENABLED on this listener (certificate \{cert}\{if require_client {", peers must present a certificate" } else {""}})",
      )
      Some(context)
    }
    Err(e) => fail(e)
  }
}
