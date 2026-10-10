// SPDX-License-Identifier: Apache-2.0
// apps/cli/profile.mbt (P23): named connection profiles.
//
// The roadmap's `profile` promise (cli-roadmap §3.1): stop repeating
// `--remote host:port` on every command. One local JSON document holds
// named profiles; one resolution point (`resolve_remote`) decides what
// a command connects to — an explicit `--remote` wins, else the
// current profile, else a refusal that names all three ways.
//
// Deliberately NOT a credential store: a token already has two
// resolutions (--token, MOONFLUX_TOKEN), and a third, silent one is a
// security decision somebody else would be making by default (P12:
// credentials are parameters). If a profile-carried token is ever
// wanted, it is its own decision with its own ticket.

///|
/// Where the config lives. `$MOONFLUX_CONFIG` overrides — tests and
/// gates must never touch a developer's real profile.
fn profile_path() -> String {
  match @env.get_env_var("MOONFLUX_CONFIG") {
    Some(path) => path
    None =>
      match @env.get_env_var("HOME") {
        Some(home) => "\{home}/.moonflux/config"
        None =>
          fail(
            "profile: no HOME and no MOONFLUX_CONFIG; cannot place the config file",
          )
      }
  }
}

///|
struct ProfileEntry {
  remote : String
} derive(Eq, Debug, Show)

///|
struct ProfileConfig {
  /// the active profile's name; rebindable by `profile use`/`remove`
  mut current : String?
  /// the registry itself is a mutable map; the binding never rebinding
  /// is how add/remove work without taking the whole struct apart
  profiles : Map[String, ProfileEntry]
}

///|
/// Loads the config. A corrupt document is an error, not an empty
/// profile set: "your profiles are gone" must never be a silent
/// fallback (the same stance as groups.json).
fn ProfileConfig::load() -> Result[ProfileConfig, String] {
  let path = profile_path()
  match @fs.exists(path) {
    Ok(false) => Ok(ProfileConfig::{ current: None, profiles: {}, })
    _ => {
      let bytes = match @fs.read_file(path) {
        Ok(bytes) => bytes
        Err(e) => return Err("read \{path}: \{e}")
      }
      let text = @utf8.decode_lossy(bytes[0:bytes.length()])
      let json = @json.parse(text[0:text.length()]) catch {
        e => return Err("corrupt \{path}: \{e}")
      }
      let obj = match json {
        Object(obj) => obj
        _ => return Err("corrupt \{path}: expected a JSON object")
      }
      let mut current : String? = None
      match obj.get("current") {
        Some(String(name)) => current = Some(name)
        Some(_) => return Err("corrupt \{path}: \"current\" must be a string")
        None => ()
      }
      let profiles : Map[String, ProfileEntry] = {}
      match obj.get("profiles") {
        Some(Object(profile_map)) =>
          for name in profile_map.keys() {
            let entry_obj = match profile_map.get(name) {
              Some(Object(entry_obj)) => entry_obj
              _ =>
                return Err("corrupt \{path}: profile \{name} must be an object")
            }
            let remote = match entry_obj.get("remote") {
              Some(String(remote)) => remote
              _ => return Err("corrupt \{path}: profile \{name} has no remote")
            }
            for key in entry_obj.keys() {
              if key == "token" {
                return Err(
                  "corrupt \{path}: profile \{name} carries a token — tokens are not profile material (use --token or MOONFLUX_TOKEN)",
                )
              }
              if key != "remote" {
                return Err(
                  "corrupt \{path}: profile \{name} has unknown field \"\{key}\"",
                )
              }
            }
            profiles[name] = ProfileEntry::{ remote, }
          }
        Some(_) => return Err("corrupt \{path}: \"profiles\" must be an object")
        None => ()
      }
      Ok(ProfileConfig::{ current, profiles, })
    }
  }
}

///|
/// Saves atomically: write beside, then rename — a half-written config
/// must not be the one the next command reads.
fn ProfileConfig::save(self : ProfileConfig) -> Result[Unit, String] {
  let path = profile_path()
  let profile_map : Map[String, Json] = {}
  for name, entry in self.profiles {
    let entry_map : Map[String, Json] = {}
    entry_map["remote"] = Json::string(entry.remote)
    profile_map[name] = Json::object(entry_map)
  }
  let doc : Map[String, Json] = {}
  match self.current {
    Some(name) => doc["current"] = Json::string(name)
    None => ()
  }
  doc["profiles"] = Json::object(profile_map)
  let text = Json::object(doc).stringify(indent=2)
  let tmp = "\{path}.tmp"
  match @fs.write_file(tmp, @utf8.encode(text[0:text.length()])) {
    Ok(_) => ()
    Err(e) => return Err("write \{tmp}: \{e}")
  }
  match @fs.rename(tmp, path) {
    Ok(_) => Ok(())
    Err(e) => Err("rename \{tmp} -> \{path}: \{e}")
  }
}

///|
/// `moonflux profile add <name> --remote host:port` — create or update
/// a profile. The first one becomes current (a user who adds a profile
/// almost always means to use it); `profile use` switches after that.
fn profile_add(argv : Array[String]) -> Unit {
  if argv.length() < 1 || argv[0].has_prefix("-") {
    fail("profile add: a name is required")
  }
  let name = argv[0]
  let flags = parse_flags(argv[1:argv.length()].to_owned())
  let remote = flags.require("remote")
  let config = match ProfileConfig::load() {
    Ok(config) => config
    Err(e) => fail("profile add: \{e}")
  }
  config.profiles[name] = ProfileEntry::{ remote, }
  if config.current is None {
    config.current = Some(name)
  }
  match config.save() {
    Ok(_) => ()
    Err(e) => fail("profile add: \{e}")
  }
  let current = match config.current {
    Some(name) => name
    None => ""
  }
  println(
    "profile \{name} -> \{remote}" +
    (if name == current { " (current)" } else { "" }),
  )
}

///|
/// `moonflux profile list` — names and remotes; the current one is
/// marked. Token material would never be here, but the rule is
/// absolute: nothing resembling a credential is ever printed.
fn profile_list(_argv : Array[String]) -> Unit {
  let config = match ProfileConfig::load() {
    Ok(config) => config
    Err(e) => fail("profile list: \{e}")
  }
  if config.profiles.length() == 0 {
    println(
      "(no profiles; add one with: moonflux profile add <name> --remote host:port)",
    )
    cli_exit(0)
  }
  let names : Array[String] = []
  for name, _ in config.profiles {
    names.push(name)
  }
  names.sort_by(fn(a, b) { a.compare(b) })
  for name in names {
    let entry = match config.profiles.get(name) {
      Some(entry) => entry
      None => continue
    }
    let mark = match config.current {
      Some(current) => if current == name { " *" } else { "" }
      None => ""
    }
    println("\{name}\t\{entry.remote}\{mark}")
  }
  cli_exit(0)
}

///|
/// `moonflux profile use <name>` — switch the current profile.
fn profile_use(argv : Array[String]) -> Unit {
  if argv.length() < 1 {
    fail("profile use: a name is required")
  }
  let name = argv[0]
  let config = match ProfileConfig::load() {
    Ok(config) => config
    Err(e) => fail("profile use: \{e}")
  }
  if config.profiles.get(name) is None {
    fail("profile use: no profile named \{name}")
  }
  config.current = Some(name)
  match config.save() {
    Ok(_) => ()
    Err(e) => fail("profile use: \{e}")
  }
  println("current profile: \{name}")
}

///|
/// `moonflux profile remove <name>` — forget a profile. Removing the
/// current one leaves nothing current (the next command says so); it
/// does not silently promote a neighbor.
fn profile_remove(argv : Array[String]) -> Unit {
  if argv.length() < 1 {
    fail("profile remove: a name is required")
  }
  let name = argv[0]
  let config = match ProfileConfig::load() {
    Ok(config) => config
    Err(e) => fail("profile remove: \{e}")
  }
  if config.profiles.get(name) is None {
    fail("profile remove: no profile named \{name}")
  }
  let _ = config.profiles.remove(name)
  match config.current {
    Some(current) => if current == name { config.current = None }
    None => ()
  }
  match config.save() {
    Ok(_) => ()
    Err(e) => fail("profile remove: \{e}")
  }
  println("removed \{name}")
}

///|
/// `moonflux profile` — the family's dispatcher.
fn cmd_profile(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("profile: missing verb (add, list, use, remove)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "add" => profile_add(rest)
    "list" => profile_list(rest)
    "use" => profile_use(rest)
    "remove" => profile_remove(rest)
    _ => fail("profile: unknown verb '\{verb}' (known: add, list, use, remove)")
  }
}

///|
/// The one place every command's `--remote` resolves: an explicit flag
/// wins, else the current profile, else a refusal that names all three
/// ways out. Commands never talk to this file themselves — one
/// resolution point means one place to change the rules.
fn resolve_remote(flags : Flags) -> String {
  match flags.get("remote") {
    Some(remote) => remote
    None => {
      let config = match ProfileConfig::load() {
        Ok(config) => config
        Err(e) => fail(e)
      }
      match config.current {
        Some(name) =>
          match config.profiles.get(name) {
            Some(entry) => entry.remote
            None =>
              fail(
                "the current profile \{name} is missing its entry; fix it with: moonflux profile add \{name} --remote host:port",
              )
          }
        None =>
          fail(
            "missing required flag --remote (or set a profile: moonflux profile add <name> --remote host:port, then it applies everywhere); commands that can act on a local store also take --data-dir DIR",
          )
      }
    }
  }
}
