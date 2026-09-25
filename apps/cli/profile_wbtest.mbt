// SPDX-License-Identifier: Apache-2.0
// White-box tests for the profile config (P23/T89): the document is the
// contract between `profile add` and every command's `resolve_remote`,
// so the round trip, the corruption refusals and the precedence live
// here rather than only in an e2e leg.

///|
fn profile_fixture(tag : String) -> String {
  let dir = "/tmp/moonflux_profile_fixture_\{tag}"
  let _ = @fs.mkdirs(dir)
  let path = "\{dir}/config"
  let _ = @fs.remove_file(path)
  let _ = @env.set_env_var("MOONFLUX_CONFIG", path)
  path
}

///|
test "profiles round trip with the current marker" {
  let _ = profile_fixture("roundtrip")
  let config = ProfileConfig::{ current: None, profiles: {} }
  config.profiles["local"] = ProfileEntry::{ remote: "127.0.0.1:19451" }
  config.profiles["staging"] = ProfileEntry::{ remote: "10.0.0.7:19451" }
  config.current = Some("staging")
  assert_true(config.save() is Ok(_))
  let loaded = match ProfileConfig::load() {
    Ok(config) => config
    Err(e) => abort("reload: \{e}")
  }
  assert_eq(
    loaded.profiles.get("local"),
    Some(ProfileEntry::{ remote: "127.0.0.1:19451" }),
  )
  assert_eq(
    loaded.profiles.get("staging"),
    Some(ProfileEntry::{ remote: "10.0.0.7:19451" }),
  )
  assert_eq(loaded.current, Some("staging"))
}

///|
test "a profile entry that carries a token is refused by name" {
  let path = profile_fixture("token")
  let _ = @fs.write_file(
    path,
    @utf8.encode(
      "{\"profiles\":{\"local\":{\"remote\":\"h:1\",\"token\":\"sekrit\"}}}",
    ),
  )
  match ProfileConfig::load() {
    Err(e) => assert_true("\{e}".contains("tokens are not profile material"))
    Ok(_) => abort("a token-bearing profile was accepted")
  }
}

///|
test "unknown fields and missing remotes are corruption, not defaults" {
  let path = profile_fixture("unknown")
  let _ = @fs.write_file(
    path,
    @utf8.encode("{\"profiles\":{\"local\":{\"remote\":\"h:1\",\"tls\":true}}}"),
  )
  match ProfileConfig::load() {
    Err(e) => assert_true("\{e}".contains("unknown field"))
    Ok(_) => abort("an unknown field was accepted")
  }
  let path2 = profile_fixture("noremote")
  let _ = @fs.write_file(path2, @utf8.encode("{\"profiles\":{\"local\":{}}}"))
  match ProfileConfig::load() {
    Err(e) => assert_true("\{e}".contains("no remote"))
    Ok(_) => abort("a profile without a remote was accepted")
  }
}

///|
test "resolve_remote: an explicit flag wins over the current profile" {
  let path = profile_fixture("resolve")
  let _ = @fs.write_file(
    path,
    @utf8.encode(
      "{\"current\":\"local\",\"profiles\":{\"local\":{\"remote\":\"127.0.0.1:1\"}}}",
    ),
  )
  // explicit flag beats the profile
  let flags = parse_flags(["--remote", "127.0.0.1:2"])
  assert_eq(resolve_remote(flags), "127.0.0.1:2")
  // no flag: the current profile answers
  let bare = parse_flags([])
  assert_eq(resolve_remote(bare), "127.0.0.1:1")
}
