// JSON representation of records, shared by the golden-vector tooling
// and tests. Pure computation: bytes travel as lowercase hex strings
// so payloads need not be UTF-8. Shape per record:
//   {"timestamp": 1726000000000, "key": "<hex>", "value": "<hex>",
//    "headers": [["<hex>", "<hex>"], ...]}
// Missing key/value/headers mean empty.

///|
fn json_to_bytes(j : Json) -> Bytes {
  if j is String(hex) {
    match @codec.hex_decode(hex) {
      Ok(data) => data
      Err(_) => b""
    }
  } else {
    b""
  }
}

///|
fn record_from_json(j : Json) -> Record {
  let timestamp = if j.value("timestamp") is Some(Number(d)) {
    d.to_int64()
  } else {
    0L
  }
  let key = if j.value("key") is Some(k) { json_to_bytes(k) } else { b"" }
  let value = if j.value("value") is Some(v) { json_to_bytes(v) } else { b"" }
  let headers : Array[(Bytes, Bytes)] = []
  if j.value("headers") is Some(Array(pairs)) {
    for pair in pairs {
      if pair is Array(kv) {
        if kv.length() == 2 {
          headers.push((json_to_bytes(kv[0]), json_to_bytes(kv[1])))
        }
      }
    }
  }
  Record::{ timestamp, key, value, headers }
}

///|
/// Parses the JSON record-list representation into records. Returns
/// `Err` with a human-readable reason on structural mismatch — this
/// is developer tooling input, so errors stay coarse-grained.
pub fn records_from_json(text : String) -> Result[Array[Record], String] {
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("invalid JSON: \{e}")
  }
  if json is Array(list) {
    let records : Array[Record] = []
    for item in list {
      records.push(record_from_json(item))
    }
    Ok(records)
  } else {
    Err("records must be a JSON array")
  }
}
