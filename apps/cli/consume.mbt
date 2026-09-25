// SPDX-License-Identifier: Apache-2.0
// consume: topic log -> stdout, one line per record:
//   <offset>\t<timestamp>\t<key>\t<value>
// Key and value render as lossy UTF-8 (P0 output is text-oriented).

///|
fn cmd_consume(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let topic = flags.require("topic")
  let from : Int64 = match flags.get("from") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => n.to_int64()
        Err(_) => fail("--from expects an integer, got \{text}")
      }
    None => 0L
  }
  let committed = flags.get("committed") is Some(_)
  let partition = match flags.get("partition") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n >= 0 => n
        _ => fail("--partition expects a non-negative integer, got \{text}")
      }
    None => 0
  }
  if flags.get("group") is Some(group) {
    // group mode: the coordinator decides which partitions this member
    // reads, and the group's committed offsets decide where
    if flags.get("remote") is None {
      fail("--group needs --remote <control plane>")
    }
    let remote = flags.require("remote")
    let member = match flags.get("member") {
      Some(member) => member
      None => "cli-\{cli_pid()}"
    }
    let follow = flags.get("follow") is Some(_)
    let commit_ms = match flags.get("commit-ms") {
      Some(text) =>
        match (try? @string.parse_int(text[0:text.length()])) {
          Ok(n) if n > 0 => n.to_int64()
          _ => fail("--commit-ms expects a positive integer, got \{text}")
        }
      None => 1000L
    }
    consume_group(
      group,
      member,
      [topic],
      remote,
      from,
      follow,
      commit_ms,
      client_token(flags),
    )
    return
  }
  match flags.get("remote") {
    Some(addr) =>
      consume_remote(
        topic,
        partition,
        from,
        addr,
        committed,
        client_token(flags),
        tls_options(flags),
      )
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      consume_local(topic, from, data_dir)
    }
  }
}

///|
/// Prints one record, and flushes. A redirected stdout is
/// block-buffered, so a consumer that is killed mid-stream (a group
/// member whose process is stopped, a reader in a pipeline that gets a
/// signal) would otherwise lose everything it had already printed —
/// and "what was delivered" is exactly what at-least-once accounting is
/// built on. The cost is one flush per record on a CLI, which is not a
/// hot path.
fn print_entry(entry : @log.LogEntry) -> Unit {
  let key = @utf8.decode_lossy(entry.record.key[0:entry.record.key.length()])
  let value = @utf8.decode_lossy(
    entry.record.value[0:entry.record.value.length()],
  )
  println("\{entry.offset}\t\{entry.record.timestamp}\t\{key}\t\{value}")
  flush_streams()
}

///|
fn consume_local(topic : String, from : Int64, data_dir : String) -> Unit {
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => fail(e)
  }
  // drain from `from` to the high watermark in bounded windows
  let mut next = from
  let mut total = 0
  while next < log.high_watermark() {
    let entries = match log.read(next, 100000) {
      Ok(entries) => entries
      Err(e) => fail("read: \{e}")
    }
    if entries.length() == 0 {
      break
    }
    for entry in entries {
      print_entry(entry)
    }
    total += entries.length()
    // advance by the last entry's offset, not by count: a compacted log
    // has holes, and a count smaller than the span would land the
    // cursor behind the tail and read it twice (P18/T76 — measured as
    // duplicated records after compaction)
    next = entries[entries.length() - 1].offset + 1L
  }
  let _ = total
  cli_exit(0)
}

///|
fn consume_remote(
  topic : String,
  partition : Int,
  from : Int64,
  addr : String,
  committed : Bool,
  token : String?,
  tls : TlsOptions?,
) -> Unit {
  let (host, port) = parse_listen_addr(addr)
  let consumer = match connect_consumer_transport(host, port, token, tls) {
    Ok(consumer) => consumer
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  // Drain in windows until the server says it has nothing more
  // (P15). One request returning "everything" was a promise no
  // transport could keep: past the reply budget the answer either
  // arrived truncated or the connection was dropped, and the caller
  // could not tell the difference between "that was all" and "that
  // was as much as fit".
  let mut next = from
  let mut first_window = true
  while true {
    if committed {
      // the committed read reports the watermarks it used on stderr,
      // so a caller can see *why* a record was withheld while stdout
      // stays a clean record stream
      match consumer.fetch_committed(topic, next, CONSUME_WINDOW) {
        Ok((entries, hw, leo)) => {
          if first_window {
            warn(
              "committed read: hw=\{hw} leo=\{leo} (records beyond the watermark are withheld)",
            )
          }
          first_window = false
          if entries.length() == 0 {
            break
          }
          for entry in entries {
            print_entry(entry)
          }
          next = entries[entries.length() - 1].offset + 1L
        }
        Err(e) => fail("committed fetch: \{e}")
      }
    } else {
      match
        consumer.fetch_partition_window(topic, partition, next, CONSUME_WINDOW) {
        Ok(window) => {
          for entry in window.entries {
            print_entry(entry)
          }
          if window.scan_end <= next {
            // no progress: either the partition ends here or a rule
            // filtered this whole window away. Either way the server
            // has told us where it stopped, so asking again would
            // repeat the same answer forever.
            break
          }
          next = window.scan_end
        }
        Err(e) => fail("fetch: \{e}")
      }
    }
  }
  consumer.close()
  cli_exit(0)
}

///|
/// How many records one fetch asks for. Not the bound that matters —
/// the server caps the reply by bytes, and it is the server's answer
/// that decides when a drain is finished (P15) — but a number large
/// enough that a fast path is one round trip rather than thousands.
const CONSUME_WINDOW : Int = 65536
