// SPDX-License-Identifier: Apache-2.0
// MQTT 3.1.1 client (P19): the subscription connector.
//
// Hand-rolled on top of net-native. The dependency rule (AGENTS §1:
// no third-party libraries; a connector's protocol client is exactly
// the kind of capability the platform is supposed to own) makes
// "write the client" the cheaper half of the trade: MQTT is a small
// binary protocol — a fixed header, a remaining-length varint, and a
// dozen control packets.
//
// Scope, stated as boundary rather than TODO: subscribe and publish at
// QoS 0. A subscription at QoS 0 makes the broker downgrade per
// min(publish, subscribe), so inbound traffic is QoS 0 — a defensive
// QoS 1 path still ACKs and skips its packet id rather than letting
// two bytes of packet id be read as payload. Outbound QoS 1 would need
// packet ids and PUBACK waits (candidate). No TLS, no will, no
// retained-message semantics, no auto-reconnect: a broken connection
// is a structured error, and retrying is the caller's business (the
// posture the cluster discipline already takes — failure is the next
// tick's problem, not a hidden retry loop).

///|
/// A parsed `mqtt://[user:pass@]host[:port]/topic` URL. The topic is
/// required — a subscription without a filter is not a subscription.
/// Credentials in the URL travel into the pipeline spec, which is
/// persisted (`topology.json`): prefer a trusted network or broker-side
/// ACLs, and know that a URL is not a secret store.
pub(all) struct MqttUrl {
  host : String
  port : Int
  topic : String
  user : String?
  password : String?
} derive(Debug)

///|
pub fn parse_mqtt_url(url : String) -> Result[MqttUrl, String] {
  if !url.has_prefix("mqtt://") {
    return Err("url must start with mqtt:// (the P19 client speaks plain TCP)")
  }
  let rest = url[7:url.length()].to_owned()
  let (authority, topic) = match rest.split_once("/") {
    Some((authority, topic)) => (authority.to_owned(), topic.to_owned())
    None => return Err("mqtt url needs a topic: mqtt://host:port/topic")
  }
  if authority.length() == 0 || topic.length() == 0 {
    return Err(
      "mqtt url needs both an authority and a topic: mqtt://[user:pass@]host[:port]/topic",
    )
  }
  let (user, password) = match authority.split_once("@") {
    Some((userinfo, _)) =>
      match userinfo.split_once(":") {
        Some((user, password)) =>
          (Some(user.to_owned()), Some(password.to_owned()))
        None => (Some(userinfo.to_owned()), None)
      }
    None => (None, None)
  }
  let hostport = match authority.split_once("@") {
    Some((_, hostport)) => hostport.to_owned()
    None => authority
  }
  let (host, port) = match hostport.rev_split_once(":") {
    Some((host, port)) =>
      match (try? @string.parse_int(port.to_owned())) {
        Ok(port) =>
          if port <= 0 || port > 65535 {
            return Err("bad port in mqtt url: \{port}")
          } else {
            (host.to_owned(), port)
          }
        Err(_) => return Err("bad port in mqtt url")
      }
    None => (hostport, 1883)
  }
  if host.length() == 0 {
    return Err("mqtt url needs a host")
  }
  Ok(MqttUrl::{ host, port, topic, user, password })
}

// ---------------------------------------------------------------------------
// Packet encoding

///|
/// The MQTT remaining-length varint: 7 bits per byte, high bit marks a
/// continuation, at most four bytes (268 435 455).
fn encode_remaining_length(len : Int) -> Bytes {
  let out = Buffer::Buffer()
  let mut value = len
  while true {
    let mut digit = value % 128
    value = value / 128
    if value > 0 {
      digit = digit | 0x80
    }
    out.write_byte(digit.to_byte())
    if value == 0 {
      break
    }
  }
  out.to_bytes()
}

///|
fn mqtt_packet(type_flags : Int, body : Bytes) -> Bytes {
  let out = Buffer::Buffer()
  out.write_byte(type_flags.to_byte())
  out.write_bytes(encode_remaining_length(body.length()))
  out.write_bytes(body)
  out.to_bytes()
}

///|
/// An MQTT UTF-8 string: two big-endian length bytes, then the bytes.
fn write_mqtt_string(buf : Buffer, text : String) -> Unit {
  let bytes = @utf8.encode(text[0:text.length()])
  buf.write_byte((bytes.length() >> 8).to_byte())
  buf.write_byte((bytes.length() & 0xFF).to_byte())
  buf.write_bytes(bytes)
}

///|
fn build_connect(
  client_id : String,
  user : String?,
  password : String?,
) -> Bytes {
  let body = Buffer::Buffer()
  write_mqtt_string(body, "MQTT")
  body.write_byte(b'\x04') // protocol level 4 = MQTT 3.1.1
  let mut flags = 0x02 // clean session: this client owns no session state
  if user is Some(_) {
    flags = flags | 0x80
  }
  if password is Some(_) {
    flags = flags | 0x40
  }
  body.write_byte(flags.to_byte())
  body.write_byte(b'\x00') // keepalive 30 s, big-endian
  body.write_byte(b'\x1e')
  write_mqtt_string(body, client_id)
  match user {
    Some(user) => write_mqtt_string(body, user)
    None => ()
  }
  match password {
    Some(password) => write_mqtt_string(body, password)
    None => ()
  }
  mqtt_packet(0x10, body.to_bytes())
}

///|
fn build_subscribe(packet_id : Int, topic : String) -> Bytes {
  let body = Buffer::Buffer()
  body.write_byte((packet_id >> 8).to_byte())
  body.write_byte((packet_id & 0xFF).to_byte())
  write_mqtt_string(body, topic)
  body.write_byte(b'\x00') // requested QoS 0
  mqtt_packet(0x82, body.to_bytes())
}

///|
fn build_publish(topic : String, payload : Bytes) -> Bytes {
  let body = Buffer::Buffer()
  write_mqtt_string(body, topic)
  body.write_bytes(payload)
  mqtt_packet(0x30, body.to_bytes())
}

///|
fn build_puback(packet_id : Int) -> Bytes {
  let body = Buffer::Buffer()
  body.write_byte((packet_id >> 8).to_byte())
  body.write_byte((packet_id & 0xFF).to_byte())
  mqtt_packet(0x40, body.to_bytes())
}

///|
fn read_uint16_be(bytes : Bytes, at : Int) -> Int {
  (bytes[at].to_int() << 8) | bytes[at + 1].to_int()
}

// ---------------------------------------------------------------------------
// Packet reading

///|
/// Reads exactly `n` bytes; a timeout mid-packet is an error — a
/// partial packet is a broken packet, and the caller has already
/// decided what "nothing at all" means before it gets here.
fn read_exact(stream : @net.TcpStream, n : Int) -> Result[Bytes, String] {
  let out = Buffer::Buffer()
  let chunk : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let mut need = n
  while need > 0 {
    match stream.recv(chunk, need) {
      Ok(0) => return Err("connection closed mid-packet")
      Ok(got) => {
        out.write_bytes(Bytes::from_fixedarray(chunk, len=got)[0:got])
        need -= got
      }
      Err(e) => return Err("recv: \{e}")
    }
  }
  Ok(out.to_bytes())
}

///|
/// One control packet as `(type_flags, body)`, or `None` when the
/// socket is quiet for the receive deadline. Only the *first* byte may
/// time out; after that a stall is a broken packet, not a quiet broker.
fn read_packet(stream : @net.TcpStream) -> Result[(Int, Bytes)?, String] {
  let head : FixedArray[Byte] = FixedArray::make(1, b'\x00')
  match stream.recv(head, 1) {
    Ok(0) => return Err("broker closed the connection")
    Ok(_) => ()
    Err(TimedOut) => return Ok(None)
    Err(e) => return Err("recv: \{e}")
  }
  let first = head[0].to_int()
  let mut remaining = 0
  let mut multiplier = 1
  let mut digits = 0
  let len_byte : FixedArray[Byte] = FixedArray::make(1, b'\x00')
  while true {
    match stream.recv(len_byte, 1) {
      Ok(0) => return Err("broker closed mid-length")
      Ok(_) => ()
      Err(TimedOut) => return Err("broker stalled mid-packet")
      Err(e) => return Err("recv: \{e}")
    }
    let digit = len_byte[0].to_int()
    remaining = remaining + (digit & 0x7F) * multiplier
    multiplier = multiplier * 128
    digits += 1
    if (digit & 0x80) == 0 {
      break
    }
    if digits == 4 {
      return Err("remaining length overflows four bytes")
    }
  }
  match read_exact(stream, remaining) {
    Ok(body) => Ok(Some((first, body)))
    Err(e) => Err(e)
  }
}

// ---------------------------------------------------------------------------
// The connector pair

///|
/// How a publish is decoded: topic, payload, and its QoS (from the
/// fixed header's low bits, so the body parser knows whether a packet
/// id sits between the topic and the payload).
priv struct Publish {
  topic : String
  payload : Bytes
  qos : Int
  packet_id : Int
}

///|
fn decode_publish(type_flags : Int, body : Bytes) -> Result[Publish, String] {
  if body.length() < 2 {
    return Err("publish shorter than its topic length")
  }
  let topic_len = read_uint16_be(body, 0)
  if body.length() < 2 + topic_len {
    return Err("publish topic runs past the packet")
  }
  let topic = @utf8.decode_lossy(body[2:2 + topic_len])
  let qos = (type_flags >> 1) & 0x03
  let mut payload_at = 2 + topic_len
  let mut packet_id = 0
  if qos > 0 {
    if body.length() < payload_at + 2 {
      return Err("publish missing its packet id")
    }
    packet_id = read_uint16_be(body, payload_at)
    payload_at += 2
  }
  Ok(Publish::{
    topic,
    payload: body[payload_at:body.length()].to_owned(),
    qos,
    packet_id,
  })
}

///|
/// A source's connection state: one broker session, reused across
/// pulls (the same reason the log cache exists — opening is not free,
/// and a per-pull reconnect would turn every quiet window into a
/// handshake).
priv struct MqttSourceState {
  mut stream : @net.TcpStream?
  mut last_io_ms : Int64
}

///|
/// MQTT source: subscribe once, then each pull drains whatever the
/// broker has sent and says `Quiet` when nothing arrived before the
/// read deadline. The record timestamp is the *arrival* time, not the
/// run's start — a subscription outlives any single instant.
pub fn mqtt_source(url : String) -> Source {
  let parsed = parse_mqtt_url(url)
  let state = MqttSourceState::{ stream: None, last_io_ms: 0L }
  Source::{
    name: "mqtt:\{url}",
    pull: fn() {
      let broker = match parsed {
        Ok(broker) => broker
        Err(e) => return Err(e)
      }
      let stream = match state.stream {
        Some(stream) => stream
        None => {
          let opened = match mqtt_open(broker, "moonflux-source") {
            Ok(stream) => stream
            Err(e) => return Err(e)
          }
          state.stream = Some(opened)
          state.last_io_ms = @env.now().reinterpret_as_int64()
          opened
        }
      }
      // keepalive: the protocol's silence limit is the broker's
      // patience, and a quiet window longer than 1.5x keepalive would
      // have the broker drop us
      let now = @env.now().reinterpret_as_int64()
      if now - state.last_io_ms > 10000L {
        match stream.send_all(b"\xc0\x00") {
          Ok(_) => state.last_io_ms = now
          Err(e) => {
            state.stream = None
            return Err("ping: \{e}")
          }
        }
      }
      let records : Array[@protocol.Record] = []
      let mut quiet = false
      while !quiet {
        match read_packet(stream) {
          Ok(None) => quiet = true
          Ok(Some((type_flags, body))) => {
            state.last_io_ms = @env.now().reinterpret_as_int64()
            let packet_type = (type_flags >> 4) & 0x0F
            if packet_type == 3 {
              // PUBLISH
              match decode_publish(type_flags, body) {
                Ok(publish) => {
                  if publish.qos == 1 {
                    // defensive: our subscription is QoS 0, so this
                    // should not happen; ACK it rather than let two
                    // packet-id bytes be read as payload
                    let _ = stream.send_all(build_puback(publish.packet_id))
                  }
                  records.push(@protocol.Record::{
                    timestamp: @env.now().reinterpret_as_int64(),
                    key: b"",
                    value: publish.payload,
                    headers: [],
                  })
                }
                Err(e) => return Err("bad publish: \{e}")
              }
            }
            // everything else (PINGRESP, broker quirks) is ignored:
            // the only packet this client acts on inbound is PUBLISH
          }
          Err(e) => {
            // any error drops the session: a half-read packet leaves
            // the stream unparsable, and "retry" is the next run's job
            state.stream = None
            return Err(e)
          }
        }
      }
      if records.length() == 0 {
        Ok(Quiet)
      } else {
        Ok(Records(records))
      }
    },
  }
}

///|
/// A sink's connection state (one session, reused across flushes).
priv struct MqttSinkState {
  mut stream : @net.TcpStream?
}

///|
/// MQTT sink: publish each record's value to the URL's topic, QoS 0.
/// The connection is lazy and kept: a streaming run publishes many
/// batches over one session. A broken connection is an error — the
/// pipeline fails loudly rather than silently dropping messages into
/// a reconnect loop.
pub fn mqtt_sink(url : String) -> Sink {
  let parsed = parse_mqtt_url(url)
  let state = MqttSinkState::{ stream: None }
  Sink::{
    name: "mqtt-publish:\{url}",
    flush: fn(records) {
      let broker = match parsed {
        Ok(broker) => broker
        Err(e) => return Err(e)
      }
      let stream = match state.stream {
        Some(stream) => stream
        None => {
          let opened = match mqtt_open(broker, "moonflux-sink") {
            Ok(stream) => stream
            Err(e) => return Err(e)
          }
          state.stream = Some(opened)
          opened
        }
      }
      for record in records {
        match stream.send_all(build_publish(broker.topic, record.value)) {
          Ok(_) => ()
          Err(e) => {
            state.stream = None
            return Err("publish: \{e}")
          }
        }
      }
      Ok(())
    },
  }
}

///|
/// Opens the session: TCP connect, CONNECT/CONNACK, SUBSCRIBE/SUBACK,
/// then the read deadline relaxes to the pull loop's quiet window
/// (handshake answers must arrive promptly; an idle broker must not).
fn mqtt_open(broker : MqttUrl, role : String) -> Result[@net.TcpStream, String] {
  let stream = match @net.TcpStream::connect(broker.host, broker.port) {
    Ok(stream) => stream
    Err(e) => return Err("connect \{broker.host}:\{broker.port}: \{e}")
  }
  match stream.set_recv_timeout_ms(2000) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("set handshake deadline: \{e}")
    }
  }
  let client_id = "\{role}-\{@env.now()}"
  match
    stream.send_all(build_connect(client_id, broker.user, broker.password)) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("send CONNECT: \{e}")
    }
  }
  // CONNACK: type 2, body = flags + return code
  match read_packet(stream) {
    Ok(Some((type_flags, body))) =>
      if ((type_flags >> 4) & 0x0F) != 2 || body.length() < 2 {
        let _ = stream.close()
        return Err("expected CONNACK, got packet type \{type_flags >> 4}")
      } else if body[1].to_int() != 0 {
        let code = body[1].to_int()
        let _ = stream.close()
        return Err("broker refused CONNECT (code \{code})")
      }
    Ok(None) => {
      let _ = stream.close()
      return Err("broker said nothing to CONNECT")
    }
    Err(e) => {
      let _ = stream.close()
      return Err(e)
    }
  }
  match stream.send_all(build_subscribe(1, broker.topic)) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("send SUBSCRIBE: \{e}")
    }
  }
  match read_packet(stream) {
    Ok(Some((type_flags, body))) =>
      if ((type_flags >> 4) & 0x0F) != 9 || body.length() < 3 {
        let _ = stream.close()
        return Err("expected SUBACK, got packet type \{type_flags >> 4}")
      } else if body[2].to_int() == 0x80 {
        let _ = stream.close()
        return Err("broker refused the subscription to \{broker.topic}")
      }
    Ok(None) => {
      let _ = stream.close()
      return Err("broker said nothing to SUBSCRIBE")
    }
    Err(e) => {
      let _ = stream.close()
      return Err(e)
    }
  }
  // subscribed: relax the deadline to the pull loop's quiet window
  match stream.set_recv_timeout_ms(300) {
    Ok(_) => ()
    Err(e) => {
      let _ = stream.close()
      return Err("set read deadline: \{e}")
    }
  }
  Ok(stream)
}
