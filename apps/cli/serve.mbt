// serve: single-process, single-connection-at-a-time broker holding
// topic logs under the data dir. P1 adds multiplexing and the fully
// versioned protocol service; P0 keeps the loop deliberately simple.

///|
fn cmd_serve(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
  let addr = flags.require("listen")
  let (host, port) = parse_listen_addr(addr)
  let listener = match @net.TcpListener::bind_listen(host, port) {
    Ok(l) => l
    Err(e) => fail("bind \{host}:\{port}: \{e}")
  }
  let actual = match listener.local_port() {
    Ok(port) => port
    Err(_) => port
  }
  println("moonflux serve listening on \{host}:\{actual} (data dir \{data_dir})")
  while true {
    match listener.accept() {
      Ok(stream) => {
        handle_connection(stream, data_dir)
        let _ = stream.close()
      }
      Err(e) => fail("accept: \{e}")
    }
  }
}

///|
/// Handles one connection: sequential request frames until the peer
/// closes. One reply frame per request.
fn handle_connection(stream : @net.TcpStream, data_dir : String) -> Unit {
  while true {
    match recv_session_frame(stream) {
      Ok(None) => return // peer closed
      Ok(Some((CMD_PRODUCE, payload))) => {
        let reply = dispatch_produce(payload, data_dir)
        let _ = send_session_frame(stream, reply.0, reply.1)
      }
      Ok(Some((CMD_FETCH, payload))) => {
        let reply = dispatch_fetch(payload, data_dir)
        let _ = send_session_frame(stream, reply.0, reply.1)
      }
      Ok(Some((_, _))) => {
        let _ = send_session_frame(stream, CMD_ERR, @utf8.encode("unknown command"[0:14]))
        return
      }
      Err(e) => {
        // framed bytes arrived but were unintelligible: report and cut
        let _ = send_session_frame(stream, CMD_ERR, @utf8.encode(e[0:e.length()]))
        return
      }
    }
  }
}

///|
fn reply(cmd : Int, payload : Bytes) -> (Int, Bytes) {
  (cmd, payload)
}

///|
fn dispatch_produce(payload : Bytes, data_dir : String) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return reply(CMD_ERR, error_payload(e))
  }
  let rest = reader.remaining()
  let frame = match reader.read_bytes(rest) {
    Ok(frame) => frame
    Err(_) => return reply(CMD_ERR, error_payload("bad produce payload"))
  }
  let records = match @protocol.decode_frame_strict(frame) {
    Ok(batch) => batch.records
    Err(e) => return reply(CMD_ERR, error_payload("bad batch: \{e}"))
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return reply(CMD_ERR, error_payload(e))
  }
  let base = match log.append(records) {
    Ok(base) => base
    Err(e) => return reply(CMD_ERR, error_payload("append: \{e}"))
  }
  let out = Buffer::Buffer()
  out.write_int64_be(base)
  out.write_uint_be(records.length().reinterpret_as_uint())
  reply(CMD_OK, out.to_bytes())
}

///|
fn dispatch_fetch(payload : Bytes, data_dir : String) -> (Int, Bytes) {
  let reader = @codec.Reader::new(payload)
  let topic = match read_topic_name(reader) {
    Ok(topic) => topic
    Err(e) => return reply(CMD_ERR, error_payload(e))
  }
  let from = match reader.read_i64_be() {
    Ok(from) => from
    Err(_) => return reply(CMD_ERR, error_payload("bad fetch payload"))
  }
  let max = match reader.read_u32_be() {
    Ok(max) => max.reinterpret_as_int()
    Err(_) => return reply(CMD_ERR, error_payload("bad fetch payload"))
  }
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return reply(CMD_ERR, error_payload(e))
  }
  let entries = match log.read(from, max) {
    Ok(entries) => entries
    Err(e) => return reply(CMD_ERR, error_payload("read: \{e}"))
  }
  // one batch frame carries the whole window; the client derives
  // per-record offsets from its base offset
  let records : Array[@protocol.Record] = []
  for entry in entries {
    records.push(entry.record)
  }
  let base : Int64 = if records.length() > 0 {
    entries[0].offset
  } else {
    from
  }
  let frame = @protocol.encode_frame(base, records)
  let out = Buffer::Buffer()
  out.write_uint_be(1U)
  out.write_uint_be(frame.length().reinterpret_as_uint())
  out.write_bytes(frame[0:frame.length()])
  reply(CMD_OK, out.to_bytes())
}

///|
fn read_topic_name(reader : @codec.Reader) -> Result[String, String] {
  let len = match reader.read_uleb128_len() {
    Ok(len) => len
    Err(_) => return Err("bad topic name")
  }
  if len > 128 {
    return Err("topic name too long")
  }
  let bytes = match reader.read_bytes(len) {
    Ok(bytes) => bytes
    Err(_) => return Err("bad topic name")
  }
  let topic = @utf8.decode_lossy(bytes[0:bytes.length()])
  if not(valid_topic(topic)) {
    return Err("invalid topic name '\{topic}'")
  }
  Ok(topic)
}

///|
fn error_payload(msg : String) -> Bytes {
  @utf8.encode(msg[0:msg.length()])
}
