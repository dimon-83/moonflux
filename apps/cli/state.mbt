// SPDX-License-Identifier: Apache-2.0
// The host half of keyed state (P30/T114). The state topic is the durable
// truth — a keyed log the block cache opens like any other, which
// compaction collapses to one record per key — and the view below is a
// cache rebuilt by replay at process start. Nothing survives in memory
// between runs on purpose: "the log is the only durable truth" is the
// whole design (docs/operator-abi-v3-state.md).
//
// Keys are text by contract. The platform's keys are byte strings, but a
// state view is a map, and a map needs a hashable key; refusing a
// non-UTF-8 state key by name is the honest version of that boundary,
// rather than a lossy decode that could silently merge two keys.

///|
/// How many keys a view may hold. A stateful pipeline with more live keys
/// than this is asking the host to keep a database in a cache, and the
/// answer is a refusal that names the limit — never a silent eviction
/// loop that quietly forgets state.
const DEFAULT_STATE_VIEW_KEYS : Int = 100000

///|
fn state_view_cap() -> Int {
  match @env.get_env_var("MOONFLUX_STATE_KEYS") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => if n > 0 { n } else { DEFAULT_STATE_VIEW_KEYS }
        Err(_) => DEFAULT_STATE_VIEW_KEYS
      }
    None => DEFAULT_STATE_VIEW_KEYS
  }
}

///|
/// One pipeline run's view of its state topic.
struct StateContext {
  data_dir : String
  topic : String
  view : Map[String, Bytes]
}

///|
/// Opens a view by replaying the state topic from its first readable
/// offset (the topic's floor, which compaction may have moved). An empty
/// value is a tombstone: it removes the key, and compaction keeps the
/// latest tombstone exactly as it keeps the latest value.
fn StateContext::open(
  data_dir : String,
  topic : String,
) -> Result[StateContext, String] {
  let log = match open_topic_log(data_dir, topic) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  let view : Map[String, Bytes] = {}
  let cap = state_view_cap()
  let mut next = log.first_offset()
  let watermark = log.high_watermark()
  while next < watermark {
    let entries = match log.read(next, 100000) {
      Ok(entries) => entries
      Err(e) => return Err("replay: \{e}")
    }
    if entries.length() == 0 {
      break
    }
    for entry in entries {
      let key = match
        (try? @utf8.decode(entry.record.key[0:entry.record.key.length()])) {
        Ok(text) => text
        Err(_) =>
          return Err(
            "the state topic holds a non-UTF-8 key at offset \{entry.offset}; state keys are text by contract",
          )
      }
      if entry.record.value.length() == 0 {
        let _ = view.remove(key)
      } else {
        view[key] = entry.record.value
      }
      if view.length() > cap {
        return Err(
          "state view is full (\{cap} keys; raise MOONFLUX_STATE_KEYS or rethink the key space) — refusing rather than evicting",
        )
      }
    }
    // advance by the last entry's offset, not by count: a compacted log
    // has holes, and a count smaller than the span would read the tail
    // twice (P18/T76)
    next = entries[entries.length() - 1].offset + 1L
  }
  Ok(StateContext::{ data_dir, topic, view, })
}

///|
/// The state entries for the keys this batch touches — the input half of
/// the v3 payload. Keys the view has never seen are simply absent.
fn StateContext::entries_for(
  self : StateContext,
  keys : Array[String],
) -> Array[@operator.StateEntry] {
  let out : Array[@operator.StateEntry] = []
  for k in keys {
    match self.view.get(k) {
      Some(value) =>
        out.push(@operator.StateEntry::{ key: @utf8.encode(k), value, })
      None => ()
    }
  }
  out
}

///|
/// Writes the guest's state back: append first (the log is the truth),
/// then update the cache. A batch whose append fails leaves the cache
/// untouched, so the next batch asks again rather than believing a value
/// that never landed.
fn StateContext::apply(
  self : StateContext,
  updates : Array[@operator.StateEntry],
) -> Result[Unit, String] {
  if updates.length() == 0 {
    return Ok(())
  }
  // the cap is checked BEFORE anything is written: a run that would grow
  // the view past its limit must leave no half-applied state behind
  let cap = state_view_cap()
  let mut live = self.view.length()
  for u in updates {
    let key = match (try? @utf8.decode(u.key[0:u.key.length()])) {
      Ok(text) => text
      Err(_) => return Err("the operator returned a non-UTF-8 state key")
    }
    // a tombstone for a key we never held does not add a live key
    if !self.view.contains(key) && u.value.length() > 0 {
      live = live + 1
    }
  }
  if live > cap {
    return Err(
      "state view is full (\{live} keys would exceed \{cap}; raise MOONFLUX_STATE_KEYS or rethink the key space) — no state was written",
    )
  }
  let log = match open_topic_log(self.data_dir, self.topic) {
    Ok(log) => log
    Err(e) => return Err(e)
  }
  let now = @env.now().reinterpret_as_int64()
  let records : Array[@protocol.Record] = []
  let texts : Array[String] = []
  for u in updates {
    let key = match (try? @utf8.decode(u.key[0:u.key.length()])) {
      Ok(text) => text
      Err(_) => return Err("the operator returned a non-UTF-8 state key")
    }
    records.push(@protocol.Record::{
      timestamp: now,
      key: u.key,
      value: u.value,
      headers: [],
    })
    texts.push(key)
  }
  match log.append(records) {
    Ok(_) => ()
    Err(e) => return Err("state append: \{e}")
  }
  for i, u in updates {
    if u.value.length() == 0 {
      let _ = self.view.remove(texts[i])
    } else {
      self.view[texts[i]] = u.value
    }
  }
  Ok(())
}

///|
/// The distinct keys a batch touches, in first-seen order, with the
/// empty-key refusal the design calls for: a stateful node with nothing
/// to key by is a mistake, not a default.
fn state_batch_keys(
  records : Array[@protocol.Record],
) -> Result[Array[String], String] {
  let keys : Array[String] = []
  for r in records {
    if r.key.length() == 0 {
      return Err(
        "a stateful operator needs a key on every record (produce --key or a key-setting operator)",
      )
    }
    let k = match (try? @utf8.decode(r.key[0:r.key.length()])) {
      Ok(text) => text
      Err(_) => return Err("record key is not UTF-8 text")
    }
    if !keys.contains(k) {
      keys.push(k)
    }
  }
  Ok(keys)
}
