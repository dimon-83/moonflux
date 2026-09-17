// SPDX-License-Identifier: Apache-2.0
// produce: file Source -> RecordBatch -> topic log (local or remote).

///|
fn cmd_produce(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let topic = flags.require("topic")
  let file = flags.require("file")
  let partition = match flags.get("partition") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) if n >= 0 => n
        _ => fail("--partition expects a non-negative integer, got \{text}")
      }
    None => 0
  }
  match flags.get("remote") {
    Some(addr) => produce_remote(topic, partition, file, addr)
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      produce_local(topic, file, data_dir)
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
/// The produce file source goes through the shared connector
/// framework (same text shaping — CRLF trimming included — as the
/// pipeline path; no duplicate implementation).
fn file_records(path : String) -> Result[Array[@protocol.Record], String] {
  let source = @connectors.file_source(path, @env.now().reinterpret_as_int64())
  (source.pull)()
}

///|
fn produce_local(topic : String, file : String, data_dir : String) -> Unit {
  let records = match file_records(file) {
    Ok(records) => records
    Err(e) => fail(e)
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => fail(e)
  }
  let base = match log.append(records) {
    Ok(base) => base
    Err(e) => fail("append: \{e}")
  }
  println(
    "produced \{records.length()} records to topic \{topic} at offsets \{base}..\{base + records.length().to_int64()} (log end \{log.high_watermark()})",
  )
  cli_exit(0)
}

///|
fn produce_remote(
  topic : String,
  partition : Int,
  file : String,
  addr : String,
) -> Unit {
  let records = match file_records(file) {
    Ok(records) => records
    Err(e) => fail(e)
  }
  let (host, port) = parse_listen_addr(addr)
  let producer = match @native.connect_producer(host, port) {
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
