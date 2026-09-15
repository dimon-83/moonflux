// SPDX-License-Identifier: Apache-2.0
// produce: file Source -> RecordBatch -> topic log (local or remote).

///|
fn cmd_produce(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let topic = flags.require("topic")
  let file = flags.require("file")
  match flags.get("remote") {
    Some(addr) => produce_remote(topic, file, addr)
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
/// Splits a text file into non-empty lines (the P0 file Source).
fn file_records(path : String) -> Result[Array[@protocol.Record], String] {
  let bytes = match @fs.read_file(path) {
    Ok(bytes) => bytes
    Err(e) => return Err("read \{path}: \{e}")
  }
  let text = @utf8.decode_lossy(bytes[0:bytes.length()])
  let records : Array[@protocol.Record] = []
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.length() > 0 {
      records.push(@protocol.Record::{
        timestamp: @env.now().reinterpret_as_int64(),
        key: b"",
        value: @utf8.encode(line[0:line.length()]),
        headers: [],
      })
    }
  }
  Ok(records)
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
fn produce_remote(topic : String, file : String, addr : String) -> Unit {
  let records = match file_records(file) {
    Ok(records) => records
    Err(e) => fail(e)
  }
  let (host, port) = parse_listen_addr(addr)
  let producer = match @client.Producer::connect(host, port) {
    Ok(producer) => producer
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  match producer.send(topic, records) {
    Ok((base, count)) =>
      println(
        "produced \{count} records to topic \{topic} at offsets \{base}..\{base + count.to_int64()}",
      )
    Err(e) => fail("send: \{e}")
  }
  producer.close()
  cli_exit(0)
}
