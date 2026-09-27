// SPDX-License-Identifier: Apache-2.0
// White-box tests for rotation (P24/T91): the load/rotate boundary.
// The TLS side needs real certificates and lives in the e2e gate;
// what pins here is the credential reload semantics — a corrupt
// document must come back as an Err (the startup caller fail-fasts,
// the reload caller keeps serving), and a changed auth.json must be
// swapped into the gate the next time the watcher checks.

///|
fn rotation_dir(tag : String) -> String {
  let dir = "/tmp/moonflux_rotation_fixture_\{tag}"
  let _ = @fs.remove_dir_all(dir)
  let _ = @fs.mkdirs(dir)
  dir
}

///|
fn write_credentials(dir : String, name : String) -> Unit {
  let body = "{\"credentials\":[{\"name\":\"\{name}\",\"token\":\"p24-token-123456\",\"role\":\"read-write\"}]}"
  let _ = @fs.write_file(
    "\{dir}/auth.json",
    @utf8.encode(body[0:body.length()]),
  )
}

///|
test "load_result answers Err for a corrupt table instead of exiting" {
  let dir = rotation_dir("corrupt")
  let _ = @fs.write_file(
    "\{dir}/auth.json",
    @utf8.encode("{\"credentials\": \"not an array\"}"),
  )
  match AuthConfig::load_result(dir) {
    Err(e) => assert_true("\{e}".contains("corrupt"))
    Ok(_) => abort("a corrupt credential table was accepted")
  }
  // absent file: trusted mode, not an error
  let empty = rotation_dir("absent")
  match AuthConfig::load_result(empty) {
    Ok(config) => assert_eq(config.credentials.length(), 0)
    Err(e) => abort("a missing auth.json is not an error: \{e}")
  }
}

///|
test "a changed auth.json is swapped in on the next check" {
  let dir = rotation_dir("swap")
  write_credentials(dir, "before")
  let gate = AuthGate::{ config: AuthConfig::load(dir), data_dir: dir, }
  assert_eq(gate.config.credentials[0].name, "before")
  let watch = RotationWatch::new(None, Some(auth_path(dir)))
  let hub = ConnectionHub::new(
    match @net.TcpListener::bind_listen("127.0.0.1", 0) {
      Ok(listener) => listener
      Err(e) => abort("bind: \{e}")
    },
    200,
  )
  watch.check(hub, gate)
  assert_eq(gate.config.credentials[0].name, "before") // unchanged material: no swap
  // replace the table wholesale: remove + write forces a fresh mtime
  let _ = @fs.remove_file("\{dir}/auth.json")
  write_credentials(dir, "after")
  watch.check(hub, gate)
  assert_eq(gate.config.credentials[0].name, "after")
  // the same check again is a no-op: rotation is a fact about the file
  watch.check(hub, gate)
  assert_eq(gate.config.credentials[0].name, "after")
}

///|
test "a vanished auth.json does not crash the watcher" {
  let dir = rotation_dir("vanished")
  write_credentials(dir, "temp")
  let gate = AuthGate::{ config: AuthConfig::load(dir), data_dir: dir, }
  let watch = RotationWatch::new(None, Some(auth_path(dir)))
  let _ = @fs.remove_file("\{dir}/auth.json")
  let hub = ConnectionHub::new(
    match @net.TcpListener::bind_listen("127.0.0.1", 0) {
      Ok(listener) => listener
      Err(e) => abort("bind: \{e}")
    },
    200,
  )
  watch.check(hub, gate)
  // the reload re-reads a missing file as trusted mode — the operator
  // removed the credentials file, and the next handshake obeys
  assert_eq(gate.config.credentials.length(), 0)
}
