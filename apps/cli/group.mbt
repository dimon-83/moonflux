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
  token : String?,
) -> Result[Bytes, String] {
  control_call_secure(sc_addr, cmd, payload, group_link(token))
}

///|
/// The link a group member presents: the credential resolved once by
/// the caller (`--token` first, then the environment — the same
/// resolution every CLI command runs) rides every group request. A
/// member that dialled without presenting a credential would look
/// exactly like a member that meant to.
fn group_link(token : String?) -> PeerLink {
  PeerLink::{ token, tls: env_tls_options() }
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
    "commit" => group_commit(rest)
    _ => fail("group: unknown verb '\{verb}' (known: list, describe, commit)")
  }
}

///|
/// `moonflux group commit --group G --member M --topic T --partition P
/// --offset O --epoch E --remote <control plane>` — asserts a commit
/// from outside the consuming process.
///
/// Two honest uses: an operator recovering a group whose data was
/// consumed out-of-band, and a test that needs to act as a member with
/// a generation that is not the current one. It is the same request a
/// live member makes, so it is fenced exactly the same way — there is
/// no privileged path.
fn group_commit(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let group = flags.require("group")
  let member = flags.require("member")
  let topic = flags.require("topic")
  let partition = match flags.get("partition") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n >= 0 => n
        _ => fail("--partition expects a non-negative integer, got \{text}")
      }
    None => 0
  }
  let offset = match flags.get("offset") {
    Some(text) =>
      match (try? @string.parse_int64(text[0:text.length()])) {
        Ok(n) if n >= 0L => n
        _ => fail("--offset expects a non-negative integer, got \{text}")
      }
    None => fail("--offset is required")
  }
  let epoch = match flags.get("epoch") {
    Some(text) =>
      match (try? @string.parse_int64(text[0:text.length()])) {
        Ok(n) => n
        _ => fail("--epoch expects an integer, got \{text}")
      }
    None =>
      fail("--epoch is required (it is the fence; guessing it is not a thing)")
  }
  let commit = @client.GroupCommit::{
    group,
    member,
    epoch,
    topic,
    partition,
    offset,
  }
  match
    group_request(
      remote,
      @client.CMD_GROUP_COMMIT,
      @client.encode_group_commit(commit),
      client_token(flags),
    ) {
    Ok(_) =>
      println(
        "committed \{topic}[\{partition}] at \{offset} for group \{group} (generation \{epoch})",
      )
    Err(e) => fail("group commit: \{e}")
  }
  cli_exit(0)
}

///|
/// `moonflux group list --remote <control plane>`
fn group_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let payload = match
    group_request(remote, @client.CMD_GROUP_DESCRIBE, b"", client_token(flags)) {
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
  let token = client_token(flags)
  let payload = match
    group_request(
      remote,
      @client.CMD_GROUP_DESCRIBE,
      @utf8.encode(name),
      client_token(flags),
    ) {
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
  // Lag is derived, and it involves two authorities: the coordinator
  // knows what was committed, the partition's leader knows how far the
  // log goes. The CLI asks both, so the number is observed rather than
  // remembered — the same stance the project takes for replica lag.
  for commit in desc.commits {
    let mut lag_text = "lag=?"
    match leader_of(remote, commit.topic, commit.partition, token) {
      Some(leader) => {
        let ref = @client.PartitionRef::{
          topic: commit.topic,
          partition: commit.partition,
        }
        match
          group_request(
            leader,
            @client.CMD_OFFSET_INFO,
            @client.encode_partition_ref(ref),
            token,
          ) {
          Ok(info) =>
            match @client.decode_offset_info(info) {
              Ok(pair) => {
                let (_hw, leo) = pair
                let lag = if leo > commit.committed {
                  leo - commit.committed
                } else {
                  0L
                }
                lag_text = "lag=\{lag}"
              }
              Err(_) => ()
            }
          Err(_) => ()
        }
      }
      None => ()
    }
    println(
      "  \{commit.topic}[\{commit.partition}]\tcommitted=\{commit.committed}\t\{lag_text}",
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
  token : String?,
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
      token,
    ) {
    Ok(payload) =>
      match @client.decode_group_view(payload) {
        Ok(view) => view
        Err(e) => fail("group join: \{e}")
      }
    Err(e) => fail("group join: \{e}")
  }
  warn(
    "joined \{group} as \{member} at generation \{view.epoch} (\{view.members} member(s)): \{membership_text(member, view.partitions)}",
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
      let leader = match
        leader_of(sc_addr, cursor.topic, cursor.partition, token) {
        Some(leader) => leader
        None => continue
      }
      let (host, port) = parse_listen_addr(leader)
      let consumer = match @native.connect_consumer(host, port) {
        Ok(consumer) => consumer
        Err(_) => continue
      }
      // the window reports where the server's scan reached, so the
      // cursor advances by the log's progress rather than by what a
      // rule happened to emit — and a byte-capped reply (P15) is not
      // mistaken for the end of the partition
      let window = match
        consumer.fetch_partition_window(
          cursor.topic,
          cursor.partition,
          cursor.next,
          1000,
        ) {
        Ok(window) => window
        Err(_) => {
          consumer.close()
          continue
        }
      }
      consumer.close()
      for entry in window.entries {
        print_entry(entry)
        cursor.next = entry.offset + 1L
        read_any = true
      }
      if window.scan_end > cursor.next {
        // nothing survived the rule chain in this window, but the
        // partition moved on: follow it, or the member would re-read
        // the same window for as long as it runs
        cursor.next = window.scan_end
        read_any = true
      }
      cursors[i] = cursor
    }
    if !follow {
      // a batch consumer: drain, commit what moved, and leave so the
      // partitions are free for the next run
      let _ = commit_cursors(sc_addr, group, member, epoch, cursors, token)
      leave_group(sc_addr, group, member, token)
      cli_exit(0)
    }
    let now = @env.now().reinterpret_as_int64()
    if now - last_commit >= commit_ms {
      last_commit = now
      // The heartbeat is what keeps this member alive, and it is not
      // the same thing as a commit: a member that is caught up has
      // nothing to commit, and a member that stopped speaking would be
      // swept and lose its partitions. It also carries the reply that
      // tells us the generation moved.
      let beat = @client.GroupHeartbeat::{
        group,
        member: @client.WireGroupMember::{
          id: member,
          address: "cli:\{cli_pid()}",
        },
      }
      match
        group_request(
          sc_addr,
          @client.CMD_GROUP_HEARTBEAT,
          @client.encode_group_heartbeat(beat),
          token,
        ) {
        Ok(payload) =>
          match @client.decode_group_view(payload) {
            Ok(fresh) =>
              if fresh.epoch != epoch {
                epoch = fresh.epoch
                adopt_view(cursors, fresh, from)
                warn(
                  "generation moved to \{epoch} for \{group}: \{membership_text(member, fresh.partitions)}",
                )
              }
            Err(_) => ()
          }
        Err(e) => warn("heartbeat \{group}: \{e}")
      }
      let stale = commit_cursors(sc_addr, group, member, epoch, cursors, token)
      if stale {
        // the commit was refused because the generation moved between
        // the heartbeat and now: re-join rather than push against a
        // fence (a re-join is idempotent for a member already in)
        warn("commit refused at generation \{epoch}; rejoining \{group}")
        match
          group_request(
            sc_addr,
            @client.CMD_GROUP_JOIN,
            @client.encode_group_join(join),
            token,
          ) {
          Ok(payload) =>
            match @client.decode_group_view(payload) {
              Ok(fresh) => {
                epoch = fresh.epoch
                adopt_view(cursors, fresh, from)
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
/// What a member holds, as one line: `member m1 holds events[0],events[1]`.
/// The coordinator knows this; logging it makes a rebalance reviewable
/// from the member's own log, and gives the gate a precise statement to
/// check (covers everything, overlaps nothing) instead of a count.
fn membership_text(
  member : String,
  partitions : Array[@client.WireGroupPartition],
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("member \{member} holds ")
  if partitions.length() == 0 {
    sb.write_string("(nothing)")
  }
  for i, p in partitions {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("\{p.topic}[\{p.partition}]")
  }
  sb.to_string()
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
  token : String?,
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
        token,
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
fn leave_group(
  sc_addr : String,
  group : String,
  member : String,
  token : String?,
) -> Unit {
  let beat = @client.GroupHeartbeat::{
    group,
    member: @client.WireGroupMember::{ id: member, address: "cli:\{cli_pid()}" },
  }
  match
    group_request(
      sc_addr,
      @client.CMD_GROUP_LEAVE,
      @client.encode_group_heartbeat(beat),
      token,
    ) {
    Ok(_) => ()
    Err(e) => warn("leave \{group}: \{e}")
  }
}

///|
/// Which node leads a partition, asked of the control plane. A member
/// reads from leaders; this is the one lookup it cannot avoid.
fn leader_of(
  sc_addr : String,
  topic : String,
  partition : Int,
  token : String?,
) -> String? {
  let ref = @client.PartitionRef::{ topic, partition }
  let payload = match
    group_request(
      sc_addr,
      @client.CMD_LEADER,
      @client.encode_partition_ref(ref),
      token,
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
