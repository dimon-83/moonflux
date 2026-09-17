// SPDX-License-Identifier: Apache-2.0
// Consuming as a group member, and the operator's view of a group (P9).
//
// A member's whole life is four verbs against the coordinator: join,
// heartbeat, commit, leave. Everything else (who holds what, what the
// group's generation is) it learns from the replies — the coordinator
// is the only place that knows, and a member that tried to work it out
// locally would be a second, disagreeing authority.

///|
/// One request to the coordinator, one reply. Short-lived connections
/// per call, like every other control-plane client here: a member does
/// not need a session, and a session is a reconnect state machine to
/// get right for no gain at this cadence.
fn group_request(
  sc_addr : String,
  cmd : Int,
  payload : Bytes,
) -> Result[Bytes, String] {
  control_call(sc_addr, cmd, payload)
}

///|
/// `moonflux group <verb> [flags]`
fn cmd_group(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("group: missing verb (list, describe)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "list" => group_list(rest)
    "describe" => group_describe(rest)
    _ => fail("group: unknown verb '\{verb}' (known: list, describe)")
  }
}

///|
/// `moonflux group list --remote <control plane>`
fn group_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let payload = match group_request(remote, @client.CMD_GROUP_DESCRIBE, b"") {
    Ok(payload) => payload
    Err(e) => fail("group list: \{e}")
  }
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => fail("group list: bad reply: \{e}")
  }
  match json {
    Array(items) =>
      for item in items {
        let name = match item.value("name") {
          Some(String(name)) => name
          _ => "?"
        }
        let epoch = match item.value("epoch") {
          Some(Number(n)) => n.to_int64()
          _ => 0L
        }
        let members = match item.value("members") {
          Some(Number(n)) => n.to_int()
          _ => 0
        }
        let commits = match item.value("commits") {
          Some(Number(n)) => n.to_int()
          _ => 0
        }
        println(
          "\{name}\tepoch=\{epoch}\tmembers=\{members}\tcommits=\{commits}",
        )
      }
    _ => fail("group list: bad reply shape")
  }
  cli_exit(0)
}

///|
/// `moonflux group describe --name G --remote <control plane>` — who is
/// in the group and how far each partition got.
fn group_describe(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let name = flags.require("name")
  let payload = match
    group_request(remote, @client.CMD_GROUP_DESCRIBE, @utf8.encode(name)) {
    Ok(payload) => payload
    Err(e) => fail("group describe: \{e}")
  }
  let desc = match @client.decode_group_description(payload) {
    Ok(desc) => desc
    Err(e) => fail("group describe: \{e}")
  }
  println("group \{desc.group}\tepoch=\{desc.epoch}")
  for member in desc.members {
    println("  member \{member.id}\t\{member.address}")
  }
  for commit in desc.commits {
    println(
      "  \{commit.topic}[\{commit.partition}]\tcommitted=\{commit.committed}",
    )
  }
  cli_exit(0)
}

///|
/// One partition's cursor as the member tracks it: where the next read
/// starts, and whether it has moved since the last commit.
struct GroupCursor {
  topic : String
  partition : Int
  mut next : Int64
  mut committed : Int64
}

///|
/// Consumes as a group member. Without `--follow` it drains its share
/// once and leaves (a batch consumer); with it, the member heartbeats,
/// commits on its interval, and keeps reading — which is what makes a
/// rebalance observable (a killed member's partitions move, the
/// survivors resume from the committed offsets).
fn consume_group(
  group : String,
  member : String,
  topics : Array[String],
  sc_addr : String,
  from : Int64,
  follow : Bool,
  commit_ms : Int64,
) -> Unit {
  let join = @client.GroupJoin::{
    group,
    member: @client.WireGroupMember::{ id: member, address: "cli:\{cli_pid()}" },
    topics,
  }
  let view = match
    group_request(
      sc_addr,
      @client.CMD_GROUP_JOIN,
      @client.encode_group_join(join),
    ) {
    Ok(payload) =>
      match @client.decode_group_view(payload) {
        Ok(view) => view
        Err(e) => fail("group join: \{e}")
      }
    Err(e) => fail("group join: \{e}")
  }
  warn(
    "joined \{group} as \{member} at generation \{view.epoch} (\{view.members} member(s)); holding \{view.partitions.length()} partition(s)",
  )
  // the broker is discovered from the leader of each partition: a
  // member reads from leaders, exactly like any other consumer
  let cursors : Array[GroupCursor] = []
  let mut epoch = view.epoch
  adopt_view(cursors, view, from)
  let mut last_commit = @env.now().reinterpret_as_int64()
  let mut idle = false
  while true {
    let mut read_any = false
    for i = 0; i < cursors.length(); i = i + 1 {
      let cursor = cursors[i]
      let leader = match leader_of(sc_addr, cursor.topic, cursor.partition) {
        Some(leader) => leader
        None => continue
      }
      let (host, port) = parse_listen_addr(leader)
      let consumer = match @native.connect_consumer(host, port) {
        Ok(consumer) => consumer
        Err(_) => continue
      }
      let entries = match
        consumer.fetch_partition(
          cursor.topic,
          cursor.partition,
          cursor.next,
          1000,
        ) {
        Ok(entries) => entries
        Err(_) => {
          consumer.close()
          continue
        }
      }
      consumer.close()
      for entry in entries {
        print_entry(entry)
        cursor.next = entry.offset + 1L
        read_any = true
      }
      cursors[i] = cursor
    }
    if !follow {
      // a batch consumer: drain, commit what moved, and leave so the
      // partitions are free for the next run
      let _ = commit_cursors(sc_addr, group, member, epoch, cursors)
      leave_group(sc_addr, group, member)
      cli_exit(0)
    }
    let now = @env.now().reinterpret_as_int64()
    if now - last_commit >= commit_ms {
      last_commit = now
      let stale = commit_cursors(sc_addr, group, member, epoch, cursors)
      if stale {
        // the generation moved: this member's partitions are not its
        // own any more. Re-join to learn the new share instead of
        // committing into a fence.
        warn("generation moved; rejoining \{group}")
        match
          group_request(
            sc_addr,
            @client.CMD_GROUP_JOIN,
            @client.encode_group_join(join),
          ) {
          Ok(payload) =>
            match @client.decode_group_view(payload) {
              Ok(fresh) => {
                epoch = fresh.epoch
                adopt_view(cursors, fresh, from)
                warn(
                  "rejoined \{group} at generation \{epoch}; holding \{fresh.partitions.length()} partition(s)",
                )
              }
              Err(_) => ()
            }
          Err(_) => ()
        }
      }
    }
    if !read_any {
      if idle {
        // nothing to read and nothing changed: wait a beat rather than
        // spin the loop hot
        sleep_ms(200)
      }
      idle = true
    } else {
      idle = false
    }
  }
}

///|
/// Adopts a coordinator view: partitions this member holds get cursors
/// (new ones start where the group last committed — or at `from`, for
/// the very first run), and partitions it no longer holds are dropped.
/// Cursor positions that survive keep their place: a rebalance must not
/// rewind a member that is still ahead.
fn adopt_view(
  cursors : Array[GroupCursor],
  view : @client.GroupView,
  from : Int64,
) -> Unit {
  let kept : Array[GroupCursor] = []
  for wire in view.partitions {
    let mut carried : GroupCursor? = None
    for cursor in cursors {
      if cursor.topic == wire.topic && cursor.partition == wire.partition {
        carried = Some(cursor)
      }
    }
    match carried {
      Some(cursor) => kept.push(cursor)
      None => {
        let start = if wire.committed > from { wire.committed } else { from }
        kept.push(GroupCursor::{
          topic: wire.topic,
          partition: wire.partition,
          next: start,
          committed: wire.committed,
        })
      }
    }
  }
  cursors.clear()
  for cursor in kept {
    cursors.push(cursor)
  }
}

///|
/// Commits every cursor that has moved. Returns true when the
/// coordinator refused because the generation moved — the member's cue
/// to re-join rather than keep pushing against a fence.
fn commit_cursors(
  sc_addr : String,
  group : String,
  member : String,
  epoch : Int64,
  cursors : Array[GroupCursor],
) -> Bool {
  let mut stale = false
  for i = 0; i < cursors.length(); i = i + 1 {
    let cursor = cursors[i]
    if cursor.next <= cursor.committed {
      continue
    }
    let commit = @client.GroupCommit::{
      group,
      member,
      epoch,
      topic: cursor.topic,
      partition: cursor.partition,
      offset: cursor.next,
    }
    match
      group_request(
        sc_addr,
        @client.CMD_GROUP_COMMIT,
        @client.encode_group_commit(commit),
      ) {
      Ok(_) => {
        cursor.committed = cursor.next
        cursors[i] = cursor
      }
      Err(e) =>
        if e.contains("epoch") {
          stale = true
        } else {
          warn("commit \{cursor.topic}[\{cursor.partition}]: \{e}")
        }
    }
  }
  stale
}

///|
fn leave_group(sc_addr : String, group : String, member : String) -> Unit {
  let beat = @client.GroupHeartbeat::{
    group,
    member: @client.WireGroupMember::{ id: member, address: "cli:\{cli_pid()}" },
  }
  match
    group_request(
      sc_addr,
      @client.CMD_GROUP_LEAVE,
      @client.encode_group_heartbeat(beat),
    ) {
    Ok(_) => ()
    Err(e) => warn("leave \{group}: \{e}")
  }
}

///|
/// Which node leads a partition, asked of the control plane. A member
/// reads from leaders; this is the one lookup it cannot avoid.
fn leader_of(sc_addr : String, topic : String, partition : Int) -> String? {
  let ref = @client.PartitionRef::{ topic, partition }
  let payload = match
    group_request(
      sc_addr,
      @client.CMD_LEADER,
      @client.encode_partition_ref(ref),
    ) {
    Ok(payload) => payload
    Err(_) => return None
  }
  match @client.decode_partition_view(payload) {
    Ok(view) => if view.leader.length() > 0 { Some(view.leader) } else { None }
    Err(_) => None
  }
}

///|
/// Waiting for the follower loop to have something to do. The clock
/// decides only how long the member pauses, never what it does: a
/// shorter or longer sleep changes how promptly a rebalance is noticed,
/// not the outcome.
fn sleep_ms(ms : Int) -> Unit {
  cli_sleep_ms(ms)
}

///|
extern "C" fn cli_sleep_ms(ms : Int) -> Unit = "mf_cli_sleep_ms"
