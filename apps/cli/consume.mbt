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
  match flags.get("remote") {
    Some(addr) => consume_remote(topic, partition, from, addr, committed)
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      consume_local(topic, from, data_dir)
    }
  }
}

///|
fn print_entry(entry : @log.LogEntry) -> Unit {
  let key = @utf8.decode_lossy(entry.record.key[0:entry.record.key.length()])
  let value = @utf8.decode_lossy(
    entry.record.value[0:entry.record.value.length()],
  )
  println("\{entry.offset}\t\{entry.record.timestamp}\t\{key}\t\{value}")
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
    next += entries.length().to_int64()
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
) -> Unit {
  let (host, port) = parse_listen_addr(addr)
  let consumer = match @native.connect_consumer(host, port) {
    Ok(consumer) => consumer
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  if committed {
    // the committed read reports the watermarks it used on stderr, so
    // a caller can see *why* a record was withheld while stdout stays
    // a clean record stream
    // committed reads keep their own command; partitioning for them
    // arrives with the per-partition watermark plumbing (P5 tail)
    match consumer.fetch_committed(topic, from, 1000000) {
      Ok((entries, hw, leo)) => {
        warn(
          "committed read: hw=\{hw} leo=\{leo} (records beyond the watermark are withheld)",
        )
        for entry in entries {
          print_entry(entry)
        }
      }
      Err(e) => fail("committed fetch: \{e}")
    }
  } else {
    let entries = match
      consumer.fetch_partition(topic, partition, from, 1000000) {
      Ok(entries) => entries
      Err(e) => fail("fetch: \{e}")
    }
    for entry in entries {
      print_entry(entry)
    }
  }
  consumer.close()
  cli_exit(0)
}
