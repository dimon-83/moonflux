// SPDX-License-Identifier: Apache-2.0
// apps/cli/audit.mbt (P21): the security audit log.
//
// One JSON line per security-relevant event — authentication outcomes,
// permission denials, topic lifecycle — appended to
// `<data-dir>/audit.log`. This is the stream an operator (or a SIEM)
// replays when the question is "who did what to my cluster", so it is
// deliberately NOT the record stream and deliberately NOT per-record:
// denials and auth events are state transitions, and auditing every
// produce would be a denial-of-service on the auditor.
//
// Two disciplines bind every writer here:
//   * credentials never enter the log — P12's gate greps for them
//   * a write that fails is announced on stderr; an audit log that
//     silently stops is worse than no audit log

///|
fn audit_path(data_dir : String) -> String {
  "\{data_dir}/audit.log"
}

///|
/// Appends one audit line. The fields arrive pre-formatted as a JSON
/// object body; the timestamp is added here so every line carries the
/// same clock discipline.
///
/// The write is deliberately **not fsynced**: audit lines land in the
/// kernel's page cache and survive a process kill (the threat that
/// matters — an operator deleting evidence), while an fsync per event
/// would run on the event loop and stretch its worst round by the
/// disk's latency — the same loop-length discipline P13 taught (a
/// stalled loop delays TLS handshakes, and a stalled handshake is how
/// replication links die). A power cut may lose the tail of this log;
/// the node's own stdout log has the same trade-off.
fn audit_line(data_dir : String, fields : String) -> Unit {
  let line = "{\"ts\":\{@env.now().reinterpret_as_int64()},\{fields}}\n"
  let file = match @fs.File::open_append(audit_path(data_dir)) {
    Ok(file) => file
    Err(e) => {
      warn("audit: cannot open \{audit_path(data_dir)}: \{e}")
      return
    }
  }
  let _ = file.write_all(@utf8.encode(line[0:line.length()]))
  let _ = file.close()
}

///|
/// An authentication outcome. `user` is the credential NAME the token
/// resolves to (or absent when nothing matched) — never the token.
fn audit_auth(
  data_dir : String,
  user : String?,
  decision : String,
  reason : String,
) -> Unit {
  let user = match user {
    Some(user) => "\"user\":\"\{user}\","
    None => ""
  }
  audit_line(
    data_dir,
    "\"event\":\"auth\",\{user}\"decision\":\"\{decision}\",\"reason\":\"\{reason}\"",
  )
}

///|
/// A permission denial (role table or per-topic grant).
fn audit_deny(
  data_dir : String,
  user : String,
  role : String,
  cmd : Int,
  topic : String?,
  reason : String,
) -> Unit {
  let topic = match topic {
    Some(topic) => "\"topic\":\"\{topic}\","
    None => ""
  }
  audit_line(
    data_dir,
    "\"event\":\"deny\",\"user\":\"\{user}\",\"role\":\"\{role}\",\"cmd\":\{cmd},\{topic}\"decision\":\"deny\",\"reason\":\"\{reason}\"",
  )
}

///|
/// A topic lifecycle event (create/delete) — the declarations an
/// operator would want on the incident timeline.
fn audit_topic(
  data_dir : String,
  user : String?,
  topic : String,
  action : String,
) -> Unit {
  let user = match user {
    Some(user) => "\"user\":\"\{user}\","
    None => ""
  }
  audit_line(
    data_dir,
    "\"event\":\"topic\",\"user\":\"\{user}\",\"topic\":\"\{topic}\",\"action\":\"\{action}\"",
  )
}

///|
/// The topic-level authorization for data commands (P21): the role
/// table ran first (the dispatcher's pre-parse gate); this is the
/// narrower per-topic question. A denial is audited here — once, with
/// the reason, and never with credentials.
fn authorize_data_command(
  identity : @auth.Identity?,
  data_dir : String,
  topic : String,
  write : Bool,
  cmd : Int,
) -> Result[Unit, (Int, String)] {
  match identity {
    None => Ok(()) // trusted mode: no credentials configured
    Some(identity) =>
      match @auth.authorize_topic(identity, topic, write~) {
        Ok(_) => Ok(())
        Err(message) => {
          audit_deny(
            data_dir,
            identity.name,
            @auth.role_name(identity.role),
            cmd,
            Some(topic),
            message,
          )
          Err((@client.ERR_FORBIDDEN, message))
        }
      }
  }
}
