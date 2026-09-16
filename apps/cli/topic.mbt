// SPDX-License-Identifier: Apache-2.0
// topic: the control plane's metadata verbs, from the command line
// (P3, docs/cli-roadmap.md §3.3). Creating a topic is *declaring* it:
// the command reports what was declared, and placement follows on the
// control plane's next reconcile — never as a side effect of the
// command itself, which is what keeps the whole design level-triggered.

///|
/// `moonflux topic <verb> [flags]`
fn cmd_topic(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("topic: missing verb (create, list, delete)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "create" => topic_create(rest)
    "list" => topic_list(rest)
    "delete" => topic_delete(rest)
    _ => fail("topic: unknown verb '\{verb}' (known: create, list, delete)")
  }
}

///|
/// `moonflux topic create --name T [--partitions N] [--replication-factor R] --remote host:port`
fn topic_create(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let name = flags.require("name")
  let partitions = match flags.get("partitions") {
    Some(text) => parse_positive(text, "partitions")
    None => 1
  }
  let rf = match flags.get("replication-factor") {
    Some(text) => parse_positive(text, "replication-factor")
    None => 1
  }
  let wire = @client.WireTopic::{ name, partitions, replication_factor: rf }
  let payload = match
    control_call(
      remote,
      @client.CMD_TOPIC_CREATE,
      @client.encode_wire_topic(wire),
    ) {
    Ok(payload) => payload
    Err(e) => fail("topic create: \{e}")
  }
  let created = match @client.decode_wire_topic(payload) {
    Ok(created) => created
    Err(e) => fail("topic create: \{e}")
  }
  println(
    "declared topic \{created.name} (\{created.partitions} partition(s), \{created.replication_factor} replica(s)); placement follows on the next reconcile",
  )
  cli_exit(0)
}

///|
/// `moonflux topic list --remote host:port`
fn topic_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let payload = match control_call(remote, @client.CMD_TOPIC_LIST, b"") {
    Ok(payload) => payload
    Err(e) => fail("topic list: \{e}")
  }
  let topics = match @client.decode_wire_topics(payload) {
    Ok(topics) => topics
    Err(e) => fail("topic list: \{e}")
  }
  for topic in topics {
    println(
      "\{topic.name}\tpartitions=\{topic.partitions}\treplication_factor=\{topic.replication_factor}",
    )
  }
  cli_exit(0)
}

///|
/// `moonflux topic delete --name T --remote host:port`
fn topic_delete(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let name = flags.require("name")
  let wire = @client.WireTopic::{ name, partitions: 0, replication_factor: 0 }
  match
    control_call(
      remote,
      @client.CMD_TOPIC_DELETE,
      @client.encode_wire_topic(wire),
    ) {
    Ok(_) => ()
    Err(e) => fail("topic delete: \{e}")
  }
  println(
    "undeclared topic \{name}; its partitions are removed on the next reconcile",
  )
  cli_exit(0)
}

///|
/// Parses a positive integer flag, with the flag's name in the error.
fn parse_positive(text : String, flag : String) -> Int {
  let value = match (try? @string.parse_int(text[0:text.length()])) {
    Ok(value) => value
    Err(_) => fail("--\{flag} must be an integer (got '\{text}')")
  }
  if value <= 0 {
    fail("--\{flag} must be positive (got \{value})")
  }
  value
}
