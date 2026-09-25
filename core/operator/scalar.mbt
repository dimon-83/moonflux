// SPDX-License-Identifier: Apache-2.0
// core/operator/scalar.mbt (P26): the scalar-call layer of ABI v2.
//
// ABI v1's seven batch exports are unchanged and untouched; this layer
// is purely additive. A guest MAY export the two scalar entry points —
// `mf_op_scalar_abi_version` (absent = the module offers no scalar
// calls, and every v1-only module keeps working) and `mf_op_eval`
// (one scalar evaluation per call). The wire format is JSON text, the
// design's first version: readable, same JSON the function-set assets
// speak, and cheap enough until a measurement says otherwise (the
// design's open question 1 — answered in the ticket, not silently).
//
// The value model here is deliberately SMALL — string, number, bool,
// array — because these are the kinds a scalar function can honestly
// take across the boundary. Bytes and objects are refused, not
// mis-marshalled (the design's mapping table, enforced).

///|
/// The scalar ABI version this host understands.
pub const SCALAR_ABI_VERSION = 1

///|
/// Optional v2 exports. Their absence is a fact about the module (a
/// v1-only operator), not an error.
pub const EXPORT_SCALAR_ABI_VERSION : String = "mf_op_scalar_abi_version"

///|
pub const EXPORT_SCALAR_EVAL : String = "mf_op_eval"

///|
/// mf_op_eval's return packs the answer's location and size into one
/// i64 so a scalar call is exactly "one allocation, one call, one read
/// back": on success `(ptr << 32) | len` — a wasm32 pointer is always
/// below 2^31, so the value stays positive — and a negative value is a
/// structured error code.
pub fn scalar_result_pack(ptr : Int, len : Int) -> Int64 {
  (ptr.to_int64() << 32) | len.to_int64()
}

///|
pub fn scalar_result_unpack(packed : Int64) -> Result[(Int, Int), Int64] {
  if packed < 0L {
    return Err(packed)
  }
  let ptr = (packed >> 32).to_int()
  let len = (packed & 0xFFFFFFFFL).to_int()
  Ok((ptr, len))
}

///|
/// The structured error codes mf_op_eval returns (< 0). Fuel
/// exhaustion is NOT a code: it surfaces as a trap, which the host
/// maps to BudgetExceeded exactly as the batch path does.
pub const SCALAR_ERR_EVAL : Int64 = -1L

///|
pub const SCALAR_ERR_REQUEST : Int64 = -2L

///|
/// The value kinds a scalar function may take across the boundary.
/// Bytes and objects are deliberately absent: they are refused at the
/// marshal, not smuggled.
pub(all) enum ScalarValue {
  SStr(String)
  SNum(Double)
  SBool(Bool)
  SArr(Array[ScalarValue])
} derive(Debug, Eq)

///|
fn scalar_to_json(v : ScalarValue) -> Json {
  match v {
    SStr(s) => Json::string(s)
    SNum(n) => Json::number(n)
    SBool(b) => Json::boolean(b)
    SArr(items) => {
      let arr : Array[Json] = []
      for item in items {
        arr.push(scalar_to_json(item))
      }
      Json::array(arr)
    }
  }
}

///|
fn scalar_of_json(json : Json) -> Result[ScalarValue, String] {
  if json == Json::boolean(true) || json == Json::boolean(false) {
    return Ok(SBool(json == Json::boolean(true)))
  }
  match json {
    String(s) => Ok(SStr(s))
    Number(n) => Ok(SNum(n))
    Array(items) => {
      let out : Array[ScalarValue] = []
      for item in items {
        match scalar_of_json(item) {
          Ok(v) => out.push(v)
          Err(e) => return Err(e)
        }
      }
      Ok(SArr(out))
    }
    Object(_) => Err("objects are not supported across the scalar boundary")
    _ => Err("null is not a scalar value")
    Object(_) => Err("objects are not supported across the scalar boundary")
  }
}

///|
/// Encodes one scalar-evaluation request: `{"fn":"tax","args":[...]}`
/// (the design's first-version encoding — the same JSON the function
/// set assets speak).
pub fn encode_scalar_request(name : String, args : Array[ScalarValue]) -> Bytes {
  let arr : Array[Json] = []
  for arg in args {
    arr.push(scalar_to_json(arg))
  }
  let doc : Map[String, Json] = {}
  doc["fn"] = Json::string(name)
  doc["args"] = Json::array(arr)
  let text = Json::object(doc).stringify()
  @utf8.encode(text[0:text.length()])
}

///|
/// Decodes a scalar-evaluation request (the guest side of the wire).
pub fn decode_scalar_request(
  payload : Bytes,
) -> Result[(String, Array[ScalarValue]), String] {
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("request is not JSON: \{e}")
  }
  let obj = match json {
    Object(obj) => obj
    _ => return Err("request must be a JSON object")
  }
  let name = match obj.get("fn") {
    Some(String(name)) => name
    _ => return Err("request has no \"fn\" name")
  }
  let args : Array[ScalarValue] = []
  match obj.get("args") {
    Some(Array(items)) =>
      for item in items {
        match scalar_of_json(item) {
          Ok(v) => args.push(v)
          Err(e) => return Err("argument: \{e}")
        }
      }
    Some(_) => return Err("request \"args\" must be an array")
    None => ()
  }
  Ok((name, args))
}

///|
/// Encodes one scalar answer: `{"v":<value>}`.
pub fn encode_scalar_answer(v : ScalarValue) -> Bytes {
  let doc : Map[String, Json] = {}
  doc["v"] = scalar_to_json(v)
  let text = Json::object(doc).stringify()
  @utf8.encode(text[0:text.length()])
}

///|
/// Decodes one scalar answer (the host side of the wire).
pub fn decode_scalar_answer(payload : Bytes) -> Result[ScalarValue, String] {
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => return Err("answer is not JSON: \{e}")
  }
  let obj = match json {
    Object(obj) => obj
    _ => return Err("answer must be a JSON object")
  }
  match obj.get("v") {
    Some(value) => scalar_of_json(value)
    None => Err("answer has no \"v\"")
  }
}
