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
  match flags.get("remote") {
    Some(addr) => consume_remote(topic, from, addr)
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
fn consume_remote(topic : String, from : Int64, addr : String) -> Unit {
  let (host, port) = parse_listen_addr(addr)
  let stream = match @net.TcpStream::connect(host, port) {
    Ok(stream) => stream
    Err(e) => fail("connect \{host}:\{port}: \{e}")
  }
  let topic_bytes = @utf8.encode(topic[0:topic.length()])
  let payload = Buffer::Buffer()
  payload.write_leb128(topic_bytes.length())
  payload.write_bytes(topic_bytes[0:topic_bytes.length()])
  payload.write_int64_be(from)
  payload.write_uint_be(1000000U)
  match send_session_frame(stream, CMD_FETCH, payload.to_bytes()) {
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
  // payload: u32 batch_count + repeat(u32 frame_len + batch frame)
  let reader = @codec.Reader::new(reply)
  let batch_count = match reader.read_u32_be() {
    Ok(count) => count.reinterpret_as_int()
    Err(_) => fail("bad fetch reply")
  }
  for _i in 0..<batch_count {
    let frame_len = match reader.read_u32_be() {
      Ok(len) => len.reinterpret_as_int()
      Err(_) => fail("bad fetch reply")
    }
    let frame = match reader.read_bytes(frame_len) {
      Ok(frame) => frame
      Err(_) => fail("bad fetch reply")
    }
    match @protocol.decode_frame_strict(frame) {
      Ok(batch) => {
        let mut offset = batch.base_offset
        for record in batch.records {
          print_entry(@log.LogEntry::{ offset, record })
          offset += 1L
        }
      }
      Err(e) => fail("bad batch in fetch reply: \{e}")
    }
  }
  let _ = stream.close()
  cli_exit(0)
}
