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
  // diagnostics belong on stderr: stdout carries data (records,
  // listings) that callers parse, and mixing the two is how a report
  // about a failure ends up looking like a record
  let bytes = @utf8.encode("error: \{msg}")
  cli_eprint(bytes, bytes.length())
  cli_exit(1)
  abort("unreachable")
}

///|
extern "C" fn flush_streams() -> Unit = "mf_cli_flush"

///|
#borrow(buf)
extern "C" fn cli_eprint(buf : Bytes, len : Int) -> Unit = "mf_cli_eprint"

///|
extern "C" fn cli_pid() -> Int = "mf_cli_pid"

///|
/// Writes one diagnostic line to stderr, flushed. Stdout carries data
/// (records) in the CLI's streaming commands and is parsed by column,
/// so anything explanatory must not land there.
fn warn(msg : String) -> Unit {
  let bytes = @utf8.encode(msg[0:msg.length()])
  cli_eprint(bytes, bytes.length())
}

///|
/// Prints one operator-facing line and flushes it. Used by the
/// long-lived node processes (serve / spu / sc): their output is
/// read while they run, and a signal can stop them between lines.
fn note(msg : String) -> Unit {
  println(msg)
  flush_streams()
}

///|
fn usage() -> Unit {
  println("usage: moonflux <command> [flags]")
  println("")
  println("commands:")
  println(
    "  produce  --topic T --file F [--key K | --key-separator S] [--partition N] [--data-dir D] [--remote host:port]",
  )
  println(
    "  consume  --topic T [--from N] [--partition N] [--group G [--member M] [--follow] [--commit-ms N]] [--data-dir D] [--remote host:port]",
  )
  println("  serve    --data-dir D --listen host:port")
  println(
    "  spu      --id A --listen host:port [--data-dir D] [--sc host:port]",
  )
  println("  sc       --listen host:port [--data-dir D]")
  println("  topic    create|list|delete --name T ...")
  println("  group    list|describe|commit --remote host:port ...")
  println("  function-set create|get|list|delete ...")
  println("  operator verify|describe|list ...")
  println("  pipeline plan|apply|run -f spec.json ...")
  println("  profile  add|list|use|remove ...")
  println("  partition list --topic T --remote host:port")
  println(
    "  benchmark produce|consume|latency --topic T [--data-dir D | --remote host:port] ...",
  )
  println("  cluster  nodes|status|leader|offsets|segments|compact|spu ...")
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
/// Flags that mean "present", not "present with a value". Consuming
/// the next argument as their value would silently eat a real flag:
/// `--committed --remote X` used to become a *local* consume of the
/// default data dir, because `--remote` became committed's value and
/// the remote branch never ran — order-dependent behavior no gate ever
/// saw, because every gate happened to write its booleans last
/// (P18/T76).
fn flag_is_boolean(name : String) -> Bool {
  name == "committed" ||
  name == "follow" ||
  name == "verify" ||
  name == "ws" ||
  name == "tls-require-client"
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
      } else if flag_is_boolean(body) {
        map[body] = ""
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
    text == "pipeline" ||
    text == "spu" ||
    text == "sc" ||
    text == "cluster" ||
    text == "topic" ||
    text == "function-set" ||
    text == "group" ||
    text == "operator" ||
    text == "benchmark" ||
    text == "profile" ||
    text == "partition"
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
    "spu" => cmd_spu(rest)
    "sc" => cmd_sc(rest)
    "cluster" => cmd_cluster(rest)
    "topic" => cmd_topic(rest)
    "function-set" => cmd_function_set(rest)
    "group" => cmd_group(rest)
    "operator" => cmd_operator(rest)
    "benchmark" => cmd_benchmark(rest)
    "profile" => cmd_profile(rest)
    "partition" => cmd_partition(rest)
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
/// The credential this process presents, from `--token` or the
/// environment. Read here, in the app layer, because the kernel's client
/// takes tokens as parameters — a library that read an env var would
/// make every embedding of it a security decision its user did not make.
fn client_token(flags : Flags) -> String? {
  match flags.get("token") {
    Some(token) => Some(token)
    None => @env.get_env_var("MOONFLUX_TOKEN")
  }
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
