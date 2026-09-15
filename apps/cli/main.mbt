// SPDX-License-Identifier: Apache-2.0
// moonflux — single binary, multiple subcommands (P0 minimal loop).
//
//   moonflux produce --topic T --file F [--data-dir D | --remote host:port]
//   moonflux consume --topic T [--from N] [--data-dir D | --remote host:port]
//   moonflux serve   --data-dir D --listen host:port
//
// Data layout: <data-dir>/topics/<topic>/partition-0.log — the
// segment file is a concatenation of wire-protocol batch frames
// (core/protocol), so files and network share one framing.

///|
extern "C" fn cli_exit(code : Int) -> Unit = "exit"

///|
/// Prints and exits; typed as `T` so call sites may use it in
/// position of any expected value (exit never returns).
fn[T] fail(msg : String) -> T {
  println("error: \{msg}")
  cli_exit(1)
  abort("unreachable")
}

///|
fn usage() -> Unit {
  println("usage: moonflux <command> [flags]")
  println("")
  println("commands:")
  println("  produce  --topic T --file F [--data-dir D] [--remote host:port]")
  println("  consume  --topic T [--from N] [--data-dir D] [--remote host:port]")
  println("  serve    --data-dir D --listen host:port")
  cli_exit(1)
}

///|
/// Parsed `--flag value` / `--flag=value` command line.
struct Flags {
  map : Map[String, String]
}

///|
fn Flags::get(self : Flags, name : String) -> String? {
  self.map.get(name)
}

///|
fn Flags::require(self : Flags, name : String) -> String {
  match self.map.get(name) {
    Some(value) => value
    None => {
      println("error: missing required flag --\{name}")
      cli_exit(1)
      abort("unreachable")
    }
  }
}

///|
fn parse_flags(argv : Array[String]) -> Flags {
  // single-dash aliases for the flags humans actually type
  fn canonical(body : String) -> String {
    match body {
      "f" => "file"
      "t" => "topic"
      "d" => "data-dir"
      other => other
    }
  }

  let map : Map[String, String] = {}
  let mut i = 0
  while i < argv.length() {
    let arg = argv[i]
    if arg.has_prefix("-") &&
      arg.length() > 1 &&
      !(arg.has_prefix("--") && arg.length() == 2) {
      let body = if arg.has_prefix("--") {
        canonical(arg[2:arg.length()].to_owned())
      } else {
        canonical(arg[1:arg.length()].to_owned())
      }
      if body.contains("=") {
        match body.split_once("=") {
          Some((name, value)) => map[name.to_owned()] = value.to_owned()
          None => ()
        }
        i += 1
      } else if i + 1 < argv.length() {
        map[body] = argv[i + 1]
        i += 2
      } else {
        map[body] = ""
        i += 1
      }
    } else {
      i += 1
    }
  }
  Flags::{ map, }
}

///|
fn main {
  let args = @env.args()
  // the runtime may or may not include the program name as args[0]:
  // find the first argument that names a subcommand
  fn is_command(text : String) -> Bool {
    text == "produce" ||
    text == "consume" ||
    text == "serve" ||
    text == "pipeline"
  }

  let start = if args.length() > 0 && is_command(args[0]) {
    0
  } else if args.length() > 1 && is_command(args[1]) {
    1
  } else {
    -1
  }
  if start < 0 || args.length() <= start + 1 {
    usage()
  }
  let cmd = args[start]
  let rest = args[start + 1:args.length()].to_owned()
  match cmd {
    "produce" => cmd_produce(rest)
    "consume" => cmd_consume(rest)
    "serve" => cmd_serve(rest)
    "pipeline" => cmd_pipeline(rest)
    _ => usage()
  }
}

///|
/// Topic names are path components. The whitelist lives in core/spec
/// (single truth, golden rule 7) so CLI-created topics and
/// spec-validated topics can never diverge; it keeps the data dir
/// traversal-proof.
fn valid_topic(topic : String) -> Bool {
  @spec.valid_topic_name(topic)
}

///|
/// Splits "host:port" (IPv4/name only for P1).
fn parse_listen_addr(addr : String) -> (String, Int) {
  match addr.rev_split_once(":") {
    Some((host, port)) =>
      match (try? @string.parse_int(port[0:port.length()])) {
        Ok(port) => (host.to_owned(), port)
        Err(_) => fail("bad port in --listen/--remote \{addr}")
      }
    None => fail("expected host:port, got \{addr}")
  }
}
