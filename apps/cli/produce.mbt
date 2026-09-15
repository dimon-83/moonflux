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
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  // payload: topic name + batch frame with unassigned base offset
  let batch = @protocol.encode_frame(-1L, records)
  let payload = Buffer::Buffer()
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_bytes(batch[0:batch.length()])
  match send_session_frame(stream, CMD_PRODUCE, payload.to_bytes()) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let reply = match recv_session_frame(stream) {
    Ok(Some((CMD_OK, payload))) => payload
    Ok(Some((CMD_ERR, payload))) =>
      fail("server: \{@utf8.decode_lossy(payload[0:payload.length()])}")
    Ok(_) => fail("unexpected reply")
    Err(e) => fail(e)
  }
  let reader = @codec.Reader::new(reply)
  let base = match reader.read_i64_be() {
    Ok(base) => base
    Err(_) => fail("bad produce reply")
  }
  let count = match reader.read_u32_be() {
    Ok(count) => count.reinterpret_as_int()
    Err(_) => fail("bad produce reply")
  }
  println(
    "produced \{count} records to topic \{topic} at offsets \{base}..\{base + count.to_int64()}",
  )
  let _ = stream.close()
  cli_exit(0)
}
