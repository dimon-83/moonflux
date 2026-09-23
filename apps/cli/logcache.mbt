// SPDX-License-Identifier: Apache-2.0
// The process's open partition logs (P16).
//
// Opening a log is not free: it recovers the tail (a scan of the last
// segment — that is *by design*, recovery is how the log finds its
// confirmed prefix) and rebuilds the active segment's anchors. Every
// request used to pay that: a produce, a fetch, a heartbeat's LEO, a
// replication round, the retention sweep. With 12 MiB segments that is
// O(segment) work per 512-record replication round, and it is not a
// slowdown in the abstract — the P15 gate measured the consequence: a
// healthy data node spent its tick budget rescanning, missed its
// heartbeat window, and the control plane declared it offline.
//
// So a process keeps what it opened. Two properties make that safe, and
// both are the reason this lives in one place rather than in each of the
// callers:
//
//   * **the cache is the only owner.** No caller keeps a handle across
//     calls; every path asks `open_partition_log` again, which is
//     exactly what this makes cheap. That is what makes eviction a
//     policy instead of a correctness bug: an evicted handle is only
//     ever one nobody is holding.
//   * **one process, one writer.** A data node owns the partitions it
//     hosts and a standalone broker owns its data dir, so the cached
//     handle is the only writer and it mutates its own state (append,
//     roll, truncate, skip_to, compaction, retention). Nothing can
//     change a log behind the cache's back, so nothing needs to
//     invalidate it.
//
// The bound exists because a broker is not the only thing that decides
// how many logs a process opens: a client can name any topic it likes,
// and each first touch creates a log. The least recently used handle
// goes, and the next touch reopens it (with a line in the log, so
// opening stopped being invisible).

///|
/// How many logs one process keeps open. Large enough for any realistic
/// partition count, small enough that a client naming a new topic per
/// request cannot exhaust the process's file descriptors.
///
/// Configurable because it is a *policy* and the gate has to exercise
/// the eviction path with two topics rather than 129 — the same
/// reasoning that made roll size and index density knobs (P8). Zero or
/// less means "no cache": every call opens afresh, which is how the
/// gate shows what the cache is worth.
fn log_cache_limit() -> Int {
  match @env.get_env_var("MOONFLUX_LOG_CACHE") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => n
        Err(_) => DEFAULT_LOG_CACHE_LIMIT
      }
    None => DEFAULT_LOG_CACHE_LIMIT
  }
}

///|
const DEFAULT_LOG_CACHE_LIMIT : Int = 128

///|
/// One cached handle, with the bookkeeping the bound needs.
priv struct CachedLog {
  /// the data dir is part of the key: a test process (or a future
  /// multi-data-dir tool) may open logs from more than one
  data_dir : String
  topic : String
  partition : Int
  log : @log.SegmentedLog
  /// the tick at which this entry was last asked for; only the *order*
  /// matters, so a monotonic counter is enough and a clock is not
  mut last_used : Int
}

///|
/// The open logs, in insertion order.
priv struct LogCache {
  mut entries : Array[CachedLog]
  /// bumped on every lookup; the eviction victim is the smallest value
  mut clock : Int
}

///|
fn LogCache::new() -> LogCache {
  LogCache::{ entries: [], clock: 0 }
}

///|
fn LogCache::get(
  self : LogCache,
  data_dir : String,
  topic : String,
  partition : Int,
) -> @log.SegmentedLog? {
  self.clock += 1
  for entry in self.entries {
    if entry.data_dir == data_dir &&
      entry.topic == topic &&
      entry.partition == partition {
      entry.last_used = self.clock
      return Some(entry.log)
    }
  }
  None
}

///|
fn LogCache::put(
  self : LogCache,
  data_dir : String,
  topic : String,
  partition : Int,
  log : @log.SegmentedLog,
) -> Unit {
  self.clock += 1
  let limit = log_cache_limit()
  if limit <= 0 {
    // caching disabled: the caller keeps the handle it just opened, and
    // the cache never holds one — the pre-P16 behaviour, kept because
    // "how much faster is it with the cache?" needs an answer the gate
    // can compute
    return
  }
  if self.entries.length() >= limit {
    let mut victim = 0
    for i = 1; i < self.entries.length(); i = i + 1 {
      if self.entries[i].last_used < self.entries[victim].last_used {
        victim = i
      }
    }
    let kept : Array[CachedLog] = []
    for i = 0; i < self.entries.length(); i = i + 1 {
      if i != victim {
        kept.push(self.entries[i])
      }
    }
    self.entries = kept
  }
  self.entries.push(CachedLog::{
    data_dir,
    topic,
    partition,
    log,
    last_used: self.clock,
  })
}

///|
/// The process's cache. One per process on purpose: the units that own
/// logs are processes (a `spu` owns the partitions it hosts, a `serve`
/// owns a data dir), and every one of them is single-threaded — which is
/// what makes "only the cache holds handles" an invariant rather than a
/// hope (AGENTS §5: per-core exclusive instances, no sharing across
/// threads).
let log_cache : LogCache = LogCache::new()

///|
/// Forgets every cached handle for one topic — the first *second write
/// path* P16 anticipated: a topic delete removes the very files those
/// handles describe, so the cache must let go of them **before** the
/// files go. A surviving entry would be a zombie — in-memory log end,
/// empty disk — exactly the state P14's leg 8 used to create by wiping
/// a directory under a running node. Returns how many handles went.
fn log_cache_evict_topic(data_dir : String, topic : String) -> Int {
  let kept : Array[CachedLog] = []
  let mut evicted = 0
  for entry in log_cache.entries {
    if entry.data_dir == data_dir && entry.topic == topic {
      evicted += 1
    } else {
      kept.push(entry)
    }
  }
  log_cache.entries = kept
  evicted
}
