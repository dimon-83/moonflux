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
const DEFAULT_STATE_VIEW_KEYS : Int32 = 100000

///|
fn state_view_cap() -> Int32 {
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
  /// When set, state writes go to the CLUSTER (the leader of the state topic)
  /// instead of the local log. That is not a preference: a node's data dir has
  /// exactly one writer per partition (P16), and a pipeline process writing
  /// the same log the node replicates would be a second writer — the node's
  /// cached end would go stale and the topic would never replicate (measured:
  /// the follower pulled "caught up to 0" while the leader held five entries).
  remote_write : ((Array[@protocol.Record]) -> Result[Unit, String])?
}

///|
/// Opens a view by replaying the state topic from its first readable
/// offset (the topic's floor, which compaction may have moved). An empty
/// value is a tombstone: it removes the key, and compaction keeps the
/// latest tombstone exactly as it keeps the latest value.
fn StateContext::open(
  data_dir : String,
  topic : String,
  remote_write : ((Array[@protocol.Record]) -> Result[Unit, String])?,
) -> Result[StateContext, String] {
  // the replay opens FRESH (never the process cache): a state topic may be
  // written by this node's own process or by another one, and a cached handle
  // sees only the bytes it saw at open (decision 72's lesson, applied to the
  // reader a stateful pipeline starts with)
  let log = match open_topic_log_shared(data_dir, topic) {
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
  Ok(StateContext::{ data_dir, topic, view, remote_write, })
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
/// The key a RUNNER reserves to record how far its input has been folded into
/// this state (P36). The state topic is the durable truth about the state; a
/// restart that wants to continue rather than replay needs one more durable
/// fact — "which input offset does this state already reflect" — and putting
/// it in the same topic, in the same append as the state it describes, is what
/// makes the pair atomic.
///
/// The name is reserved, not magic: an operator that returns a state entry for
/// this key is refused by name (see `stage`), because a state key that means
/// two things means nothing.
const STATE_PROGRESS_KEY : String = "__moonflux_progress__"

///|
/// The input offset this state has already absorbed, or None on a state topic
/// that has never recorded one (the first run).
fn StateContext::progress(self : StateContext) -> Int64? {
  match self.view.get(STATE_PROGRESS_KEY) {
    Some(value) => {
      let text = @utf8.decode_lossy(value)
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => Some(n.to_int64())
        Err(_) => None
      }
    }
    None => None
  }
}

///|
/// Stages the guest's state in the VIEW (so a later node in the same batch
/// sees it) and returns the entries to append. Nothing is durable until
/// `commit`.
///
/// Staging exists because of what this used to do: each stateful node
/// appended on its own, so a chain with two of them had two appends per
/// batch and a crash between them left half a batch's state written — which
/// contradicts the documented "one batch is one transaction" (decision 60).
/// One append per batch is that promise kept.
fn StateContext::stage(
  self : StateContext,
  updates : Array[@operator.StateEntry],
) -> Result[Array[@operator.StateEntry], String] {
  // the cap is checked BEFORE anything is staged or written: a run that would
  // grow the view past its limit must leave no half-applied state behind
  let cap = state_view_cap()
  let mut live = self.view.length()
  for u in updates {
    let key = match (try? @utf8.decode(u.key[0:u.key.length()])) {
      Ok(text) => text
      Err(_) => return Err("the operator returned a non-UTF-8 state key")
    }
    if key == STATE_PROGRESS_KEY {
      return Err(
        "the operator returned a state entry for \{STATE_PROGRESS_KEY}, which this runner reserves for its own progress",
      )
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
  for u in updates {
    let key = @utf8.decode_lossy(u.key[0:u.key.length()])
    if u.value.length() == 0 {
      let _ = self.view.remove(key)
    } else {
      self.view[key] = u.value
    }
  }
  Ok(updates)
}

///|
/// Makes a batch's state durable in ONE append: the entries every stateful
/// node in the chain staged, plus the runner's progress marker when there is
/// one (a topic source has offsets; a file has none).
///
/// The marker is written last, in the same frame as the state it describes. A
/// crash before the append loses the whole batch (and `--resume` re-reads it);
/// a crash after it loses nothing. That is the exactly-once-ish boundary this
/// feature can honestly claim: not a transaction log, but one frame whose
/// contents agree with each other.
fn StateContext::commit(
  self : StateContext,
  entries : Array[@operator.StateEntry],
  progress : Int64?,
) -> Result[Unit, String] {
  let to_write : Array[@operator.StateEntry] = []
  for e in entries {
    to_write.push(e)
  }
  match progress {
    Some(next_offset) =>
      to_write.push(@operator.StateEntry::{
        key: @utf8.encode(STATE_PROGRESS_KEY),
        value: @utf8.encode(next_offset.to_string()),
      })
    None => ()
  }
  if to_write.length() == 0 {
    return Ok(())
  }
  let now = @env.now().reinterpret_as_int64()
  let records : Array[@protocol.Record] = []
  for u in to_write {
    records.push(@protocol.Record::{
      timestamp: now,
      key: u.key,
      value: u.value,
      headers: [],
    })
  }
  match self.remote_write {
    Some(write) =>
      // one call, one batch: the node appends it as one frame, so the batch's
      // state and its progress marker stay atomic exactly as they are locally
      write(records)
    None => {
      let log = match open_topic_log(self.data_dir, self.topic) {
        Ok(log) => log
        Err(e) => return Err(e)
      }
      match log.append(records) {
        Ok(_) => Ok(())
        Err(e) => Err("state append: \{e}")
      }
    }
  }
}

///|
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
