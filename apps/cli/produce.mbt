// SPDX-License-Identifier: Apache-2.0
// produce: file Source -> RecordBatch -> topic log (local or remote).

///|
fn cmd_produce(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let topic = flags.require("topic")
  let file = flags.require("file")
  let key_mode = match flags.get("key") {
    Some(key) =>
      match flags.get("key-separator") {
        Some(_) => fail("--key and --key-separator are mutually exclusive")
        None => @connectors.ConstKey(@utf8.encode(key[0:key.length()]))
      }
    None =>
      match flags.get("key-separator") {
        Some(sep) =>
          if sep.length() == 0 {
            fail("--key-separator must not be empty")
          } else {
            @connectors.SplitAt(sep)
          }
        None => @connectors.NoKey
      }
  }
  let partition = match flags.get("partition") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n >= 0 => n
        _ => fail("--partition expects a non-negative integer, got \{text}")
      }
    None => 0
  }
  match flags.get("remote") {
    Some(addr) =>
      produce_remote(
        topic,
        partition,
        file,
        key_mode,
        addr,
        client_token(flags),
        tls_options(flags),
      )
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      produce_local(topic, file, key_mode, data_dir)
    }
  }
}

///|
fn unwrap_or(opt : String?, fallback : String) -> String {
  match opt {
    Some(v) => v
    None => fallback
  }
}

///|
/// The produce file source goes through the shared connector shaping
/// rule (same text shaping — CRLF trimming included — as the pipeline
/// path; no duplicate implementation), plus the key mode and the skip
/// count the keyed modes must report.
fn file_records(
  path : String,
  key_mode : @connectors.KeyMode,
) -> Result[Array[@protocol.Record], String] {
  let shaped = match
    @connectors.file_records_keyed(
      path,
      @env.now().reinterpret_as_int64(),
      key_mode,
    ) {
    Ok(shaped) => shaped
    Err(e) => return Err(e)
  }
  if shaped.skipped > 0 {
    warn(
      "warning: skipped \{shaped.skipped} line(s) without the key separator\n",
    )
  }
  Ok(shaped.records)
}

///|
fn produce_local(
  topic : String,
  file : String,
  key_mode : @connectors.KeyMode,
  data_dir : String,
) -> Unit {
  let records = match file_records(file, key_mode) {
    Ok(records) => records
    Err(e) => fail(e)
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => fail(e)
  }
  // the same chunking the wire path does, for the same reason: the
  // kernel refuses a batch over `MAX_BATCH_BYTES` (`BatchTooLarge`), and
  // a 20 MiB file used to hit that wall on the local path while the
  // remote path had already learned to split it (P15). One rule for
  // both directions: a file is as big as the operator wants, a frame
  // is not.
  let batches = @protocol.split_batches(records, @client.PRODUCE_CHUNK_BYTES)
  let mut first : Int64 = 0L
  let mut total = 0
  for index, batch in batches {
    let base = match log.append(batch) {
      Ok(base) => base
      Err(e) => fail("append: \{e}")
    }
    if index == 0 {
      first = base
    }
    total += batch.length()
  }
  println(
    "produced \{total} records to topic \{topic} at offsets \{first}..\{first + total.to_int64()} (log end \{log.high_watermark()})",
  )
  cli_exit(0)
}

///|
fn produce_remote(
  topic : String,
  partition : Int,
  file : String,
  key_mode : @connectors.KeyMode,
  addr : String,
  token : String?,
  tls : TlsOptions?,
) -> Unit {
  let records = match file_records(file, key_mode) {
    Ok(records) => records
    Err(e) => fail(e)
  }
  let (host, port) = parse_listen_addr(addr)
  let producer = match connect_producer_transport(host, port, token, tls) {
    Ok(producer) => producer
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  let produced = if partition == 0 {
    producer.send(topic, records)
  } else {
    producer.send_partition(topic, partition, records)
  }
  match produced {
    Ok((base, count)) =>
      println(
        "produced \{count} records to topic \{topic}[\{partition}] at offsets \{base}..\{base + count.to_int64()}",
      )
    Err(e) => fail("send: \{e}")
  }
  producer.close()
  cli_exit(0)
}
