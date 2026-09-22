// SPDX-License-Identifier: Apache-2.0
// benchmark: throughput and latency baselines for the data plane (P17).
//
//   benchmark produce  --topic T [--records N] [--record-size B] [--batch-records K] [--data-dir D | --remote host:port]
//   benchmark consume  --topic T [--from N] [--verify] [--data-dir D | --remote host:port]
//   benchmark latency  --topic T [--samples N] [--record-size B] [--data-dir D | --remote host:port]
//
// The reference system's benchmark is a producer throughput run plus a
// latency histogram; its consumer benchmark is hidden and unpublished
// (evaluation report §2.12). moonflux adds the consume and the
// produce→consume visibility modes because the P16 regression guard
// needs both directions of the path.
//
// Numbers are reports, never gates: the same data must not pass on an
// idle laptop and fail on a loaded CI runner (decision 33 — the wall
// clock only reports). What a gate may assert about a benchmark is its
// structure: counts, offset ranges, percentile monotonicity, and the
// server's `opened` line count.

///|
/// A monotonic microsecond clock. The environment's clock is
/// millisecond-resolution and a local round trip is not — a histogram
/// whose p50 rounds to 0 is not a baseline. Monotonic rather than wall
/// time on purpose: a benchmark measures intervals, and intervals must
/// not jump when NTP corrects the wall clock. Host-side only, like
/// every clock this CLI touches (the kernel stays clock-free, AGENTS
/// §5).
extern "C" fn cli_now_us() -> Int64 = "mf_cli_now_us"

///|
/// The benchmark value: 4 big-endian bytes naming the record's own
/// offset, then dot fill. The header is the cheapest integrity check
/// available under load — `--verify` re-derives it on the way out, and
/// a reply whose base is misplaced breaks it on the first record (the
/// class of bug P15 fixed in the fetch path; this is the tripwire for
/// the next one). The fill is dots so a value that leaks into human
/// output is recognisable.
const BENCH_HEADER_BYTES : Int = 4

///|
/// How many records one fetch window asks for. Not the bound that
/// matters — the server caps the reply by bytes and its `scan_end`
/// decides when the drain is done (P15) — just large enough that a
/// fast path is one round trip.
const BENCH_FETCH_WINDOW : Int = 65536

///|
fn bench_fill_bytes(count : Int) -> Bytes {
  let chunk = b"................................"
  let buf = Buffer::Buffer()
  let mut left = count
  while left > 0 {
    let take = if left > chunk.length() { chunk.length() } else { left }
    buf.write_bytes(chunk[0:take])
    left -= take
  }
  buf.to_bytes()
}

///|
fn bench_value(offset : Int64, size : Int, fill : Bytes) -> Bytes {
  let buf = Buffer::Buffer()
  buf.write_uint_be(offset.to_int().reinterpret_as_uint())
  buf.write_bytes(fill)
  buf.to_bytes()
}

///|
/// The offset a benchmark value carries in its header. Bytes indexing
/// yields a `Byte`, not an `Int` — shifting it truncates back to 8
/// bits, so every byte is widened before the arithmetic.
fn bench_value_offset(value : Bytes) -> Int64 {
  let b0 = value[0].to_int()
  let b1 = value[1].to_int()
  let b2 = value[2].to_int()
  let b3 = value[3].to_int()
  ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3).to_int64()
}

///|
/// A benchmark record is intact when its value header names its own
/// offset. Values too short to carry a header count as intact —
/// `--verify` is about the records the benchmark wrote, and the
/// operator pointed it at this topic.
fn bench_entry_ok(entry : @log.LogEntry) -> Bool {
  let value = entry.record.value
  if value.length() < BENCH_HEADER_BYTES {
    return true
  }
  bench_value_offset(value) == entry.offset
}

///|
/// Nearest-rank percentile: the ceil(p·n/100)-th smallest, 1-based.
/// Integer arithmetic on purpose — no float rounding anywhere near a
/// reported number. p=0 is the minimum, p=100 the maximum; an empty
/// sample set is the caller's bug and clamps to rank 1 (callers that
/// can see zero samples guard before indexing).
fn percentile_rank(n : Int, p : Int) -> Int {
  let rank = (p * n + 99) / 100
  if rank < 1 {
    1
  } else if rank > n {
    n
  } else {
    rank
  }
}

///|
/// The `p`-th percentile of an ascending-sorted sample array.
fn percentile_us(sorted : Array[Int64], p : Int) -> Int64 {
  sorted[percentile_rank(sorted.length(), p) - 1]
}

///|
/// One histogram line, µs throughout: `label min=.. avg=.. p50=.. p90=.. p99=.. max=.. count=..`.
/// Takes the array (sorts it in place — callers hand it over once).
fn stats_line(label : String, samples : Array[Int64]) -> String {
  samples.sort()
  let n = samples.length()
  if n == 0 {
    return "\{label} count=0"
  }
  let mut sum = 0L
  for sample in samples {
    sum += sample
  }
  let avg = sum / n.to_int64()
  "\{label} min=\{percentile_us(samples, 0)} avg=\{avg} p50=\{percentile_us(samples, 50)} p90=\{percentile_us(samples, 90)} p99=\{percentile_us(samples, 99)} max=\{percentile_us(samples, 100)} count=\{n}"
}

///|
/// A positive integer flag with a default, or a failure that names the
/// flag and the value that failed to parse.
fn require_positive(flags : Flags, name : String, fallback : Int) -> Int {
  match flags.get(name) {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) =>
          if n > 0 {
            n
          } else {
            fail("--\{name} expects a positive integer, got \{text}")
          }
        Err(_) => fail("--\{name} expects a positive integer, got \{text}")
      }
    None => fallback
  }
}

///|
/// The byte size of one benchmark record. The floor is the header: a
/// value that cannot carry its own offset is not verifiable, and an
/// unverifiable benchmark record is just noise. The ceiling is the
/// producer's own per-field limit — refusing here, by name, in this
/// process is the P15 rule (never ship it for the server to reject).
fn bench_record_size(flags : Flags) -> Int {
  let size = require_positive(flags, "record-size", 256)
  if size < BENCH_HEADER_BYTES + 1 {
    fail(
      "--record-size must be at least \{BENCH_HEADER_BYTES + 1} bytes (\{BENCH_HEADER_BYTES} of header plus payload)",
    )
  }
  if size > @protocol.MAX_RECORD_BYTES {
    fail(
      "--record-size of \{size} bytes exceeds the \{@protocol.MAX_RECORD_BYTES}-byte per-field limit; a record this large is refused by name, not shipped for the server to reject",
    )
  }
  size
}

///|
/// Records per benchmark batch, bounded so one batch stays under the
/// producer's chunk size: one send is then exactly one frame, and a
/// batch's timing means one round trip instead of some uncontrolled
/// number of them.
fn bench_batch_records(flags : Flags, size : Int) -> Int {
  let batch = require_positive(flags, "batch-records", 512)
  let sample = @protocol.Record::{
    timestamp: @env.now().reinterpret_as_int64(),
    key: b"",
    value: bench_value(0L, size, bench_fill_bytes(size - BENCH_HEADER_BYTES)),
    headers: [],
  }
  let wire = @protocol.record_wire_size(sample) * batch +
    @protocol.FRAME_OVERHEAD_BYTES
  if wire > @client.PRODUCE_CHUNK_BYTES {
    fail(
      "--batch-records of \{batch} at \{size} B/record is \{wire} B on the wire, over the \{@client.PRODUCE_CHUNK_BYTES}-byte chunk: one benchmark batch must be one frame for its timing to mean anything",
    )
  }
  batch
}

///|
/// One batch of benchmark records starting at `base`.
fn bench_batch(
  base : Int64,
  count : Int,
  size : Int,
  fill : Bytes,
) -> Array[@protocol.Record] {
  let records : Array[@protocol.Record] = []
  for i = 0; i < count; i = i + 1 {
    records.push(@protocol.Record::{
      timestamp: @env.now().reinterpret_as_int64(),
      key: b"",
      value: bench_value(base + i.to_int64(), size, fill),
      headers: [],
    })
  }
  records
}

///|
/// Throughput as two integer rates. Zero elapsed (a run shorter than
/// the clock's granularity) reports 0 rather than dividing by zero.
fn report_throughput(records : Int, bytes : Int64, elapsed_us : Int64) -> Unit {
  let (rps, bps) = if elapsed_us > 0L {
    (records.to_int64() * 1000000L / elapsed_us, bytes * 1000000L / elapsed_us)
  } else {
    (0L, 0L)
  }
  println("throughput records_per_sec=\{rps} bytes_per_sec=\{bps}")
}

///|
fn cmd_benchmark(argv : Array[String]) -> Unit {
  if argv.length() == 0 || argv[0].has_prefix("-") {
    fail(
      "usage: benchmark produce|consume|latency --topic T [--data-dir D | --remote host:port] ...",
    )
  }
  let mode = argv[0]
  let flags = parse_flags(argv)
  match mode {
    "produce" => bench_produce(flags)
    "consume" => bench_consume(flags)
    "latency" => bench_latency(flags)
    other => fail("unknown benchmark mode: \{other}")
  }
}

///|
/// Produce `--records` synthetic records in timed batches and report
/// throughput plus a per-batch latency histogram (remote: one ack round
/// trip per batch; local: one append). Offset continuity within the run
/// is an invariant, not a metric — a send whose base is not the running
/// base is a correctness bug wearing a timing report, and the benchmark
/// refuses to print one.
fn bench_produce(flags : Flags) -> Unit {
  let topic = flags.require("topic")
  let records = require_positive(flags, "records", 10000)
  let size = bench_record_size(flags)
  let batch_records = bench_batch_records(flags, size)
  let fill = bench_fill_bytes(size - BENCH_HEADER_BYTES)
  let batch_us : Array[Int64] = []
  let mut sent = 0
  let mut batches = 0
  let mut base = 0L
  let mut first_base = 0L
  let t0 = cli_now_us()
  match flags.get("remote") {
    Some(addr) => {
      let (host, port) = parse_listen_addr(addr)
      let producer = match
        connect_producer_transport(
          host,
          port,
          client_token(flags),
          tls_options(flags),
        ) {
        Ok(producer) => producer
        Err(e) => fail("connect \{host}:\{port}: \{e}")
      }
      while sent < records {
        let take = if batch_records < records - sent {
          batch_records
        } else {
          records - sent
        }
        let batch = bench_batch(base, take, size, fill)
        let started = cli_now_us()
        let reply = match producer.send(topic, batch) {
          Ok(reply) => reply
          Err(e) => fail("send: \{e}")
        }
        batch_us.push(cli_now_us() - started)
        let (got_base, got_count) = reply
        // the first batch adopts whatever offset the topic is at; every
        // later one must continue it exactly
        if batches == 0 {
          base = got_base
          first_base = got_base
        }
        if got_base != base || got_count != take {
          fail(
            "offset discontinuity: batch \{batches} reported \{got_base}..\{got_base + got_count.to_int64()}, expected \{base}..\{base + take.to_int64()}",
          )
        }
        base += take.to_int64()
        sent += take
        batches += 1
      }
      producer.close()
    }
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      let log = match open_topic_log(data_dir, topic) {
        Ok(log) => log
        Err(e) => fail(e)
      }
      while sent < records {
        let take = if batch_records < records - sent {
          batch_records
        } else {
          records - sent
        }
        let batch = bench_batch(base, take, size, fill)
        let started = cli_now_us()
        let got_base = match log.append(batch) {
          Ok(got_base) => got_base
          Err(e) => fail("append: \{e}")
        }
        batch_us.push(cli_now_us() - started)
        if batches == 0 {
          base = got_base
          first_base = got_base
        }
        if got_base != base {
          fail(
            "offset discontinuity: batch \{batches} appended at \{got_base}, expected \{base}",
          )
        }
        base += take.to_int64()
        sent += take
        batches += 1
      }
    }
  }
  let elapsed_us = cli_now_us() - t0
  let bytes = records.to_int64() * size.to_int64()
  let mode = if flags.get("remote") is Some(_) { "remote" } else { "local" }
  println(
    "benchmark produce topic=\{topic} mode=\{mode} records=\{records} record_size=\{size} batch_records=\{batch_records}",
  )
  println(
    "result records=\{sent} base_offset=\{first_base} end_offset=\{base} bytes=\{bytes} batches=\{batches} elapsed_us=\{elapsed_us}",
  )
  report_throughput(sent, bytes, elapsed_us)
  println(stats_line("batch_latency_us", batch_us))
  cli_exit(0)
}

///|
/// Drain the topic in windows (local or remote) and report throughput.
/// `--verify` re-derives every value's offset header; a mismatch fails
/// the run — integrity under load is a correctness fact, not a number.
fn bench_consume(flags : Flags) -> Unit {
  let topic = flags.require("topic")
  let from : Int64 = match flags.get("from") {
    Some(text) =>
      match (try? @string.parse_int(text[0:text.length()])) {
        Ok(n) => n.to_int64()
        Err(_) => fail("--from expects an integer, got \{text}")
      }
    None => 0L
  }
  let verify = flags.get("verify") is Some(_)
  let mut next = from
  let mut count = 0
  let mut bytes = 0L
  let mut windows = 0
  let mut sequence_ok = true
  let t0 = cli_now_us()
  fn account(entry : @log.LogEntry) -> Unit {
    bytes += entry.record.value.length().to_int64()
    if verify && !bench_entry_ok(entry) {
      if sequence_ok {
        warn(
          "sequence mismatch at offset \{entry.offset}: value header says \{bench_value_offset(entry.record.value)}",
        )
      }
      sequence_ok = false
    }
    count += 1
  }
  match flags.get("remote") {
    Some(addr) => {
      let (host, port) = parse_listen_addr(addr)
      let consumer = match
        connect_consumer_transport(
          host,
          port,
          client_token(flags),
          tls_options(flags),
        ) {
        Ok(consumer) => consumer
        Err(e) => fail("connect \{host}:\{port}: \{e}")
      }
      // drain until the server says its scan ended the partition —
      // "fewer rows than asked" is not an end signal (P15)
      while true {
        let window = match
          consumer.fetch_partition_window(topic, 0, next, BENCH_FETCH_WINDOW) {
          Ok(window) => window
          Err(e) => fail("fetch: \{e}")
        }
        windows += 1
        for entry in window.entries {
          account(entry)
        }
        if window.scan_end <= next {
          next = window.scan_end
          break
        }
        next = window.scan_end
      }
      consumer.close()
    }
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      let log = match open_topic_log(data_dir, topic) {
        Ok(log) => log
        Err(e) => fail(e)
      }
      while next < log.high_watermark() {
        let entries = match
          log.read_bounded(next, BENCH_FETCH_WINDOW, @client.FETCH_WINDOW_BYTES) {
          Ok(entries) => entries
          Err(e) => fail("read: \{e}")
        }
        windows += 1
        if entries.length() == 0 {
          break
        }
        for entry in entries {
          account(entry)
        }
        next += entries.length().to_int64()
      }
    }
  }
  let elapsed_us = cli_now_us() - t0
  let mode = if flags.get("remote") is Some(_) { "remote" } else { "local" }
  println(
    "benchmark consume topic=\{topic} mode=\{mode} from=\{from} verify=\{verify}",
  )
  println(
    "result records=\{count} bytes=\{bytes} end_offset=\{next} windows=\{windows} elapsed_us=\{elapsed_us}",
  )
  report_throughput(count, bytes, elapsed_us)
  if verify {
    if sequence_ok {
      println("sequence_ok=true")
    } else {
      println("sequence_ok=false")
      cli_exit(1)
    }
  }
  cli_exit(0)
}

///|
/// `--samples` rounds of produce-one-then-consume-until-visible on two
/// persistent connections, reporting a produce-ack and an end-to-end
/// visibility histogram. The cursor starts wherever the topic actually
/// is (probed by draining), so the run works on a fresh topic and on
/// one with history alike.
fn bench_latency(flags : Flags) -> Unit {
  let topic = flags.require("topic")
  let samples = require_positive(flags, "samples", 30)
  let size = bench_record_size(flags)
  let fill = bench_fill_bytes(size - BENCH_HEADER_BYTES)
  let ack_us : Array[Int64] = []
  let e2e_us : Array[Int64] = []
  let mut produced = 0
  let mut consumed = 0
  let mut sequence_ok = true
  fn sample_record(offset : Int64) -> @protocol.Record {
    @protocol.Record::{
      timestamp: @env.now().reinterpret_as_int64(),
      key: b"",
      value: bench_value(offset, size, fill),
      headers: [],
    }
  }
  match flags.get("remote") {
    Some(addr) => {
      let (host, port) = parse_listen_addr(addr)
      let producer = match
        connect_producer_transport(
          host,
          port,
          client_token(flags),
          tls_options(flags),
        ) {
        Ok(producer) => producer
        Err(e) => fail("connect \{host}:\{port}: \{e}")
      }
      let consumer = match
        connect_consumer_transport(
          host,
          port,
          client_token(flags),
          tls_options(flags),
        ) {
        Ok(consumer) => consumer
        Err(e) => fail("connect \{host}:\{port}: \{e}")
      }
      // probe the current end by draining: `scan_end` stops advancing
      // at the end, and a window capped at N records reports a scan
      // that stopped at N — the drain is the only probe that cannot
      // lie about where the log ends
      let mut cursor = 0L
      while true {
        let window = match
          consumer.fetch_partition_window(topic, 0, cursor, BENCH_FETCH_WINDOW) {
          Ok(window) => window
          Err(e) => fail("fetch: \{e}")
        }
        if window.scan_end <= cursor {
          break
        }
        cursor = window.scan_end
      }
      for i = 0; i < samples; i = i + 1 {
        let t0 = cli_now_us()
        let (base, count) = match
          producer.send(topic, [sample_record(cursor)]) {
          Ok(reply) => reply
          Err(e) => fail("send: \{e}")
        }
        let ack = cli_now_us() - t0
        if base != cursor || count != 1 {
          fail(
            "offset discontinuity: sample \{i} produced at \{base}..\{base + count.to_int64()}, expected \{cursor}",
          )
        }
        produced += 1
        // the produce reply means the record is appended; fetch until
        // it is visible — on a live serve this is one round trip, and
        // the retry is for the day something gets between the two
        let mut seen = false
        let mut tries = 0
        while !seen && tries < 25 {
          let window = match
            consumer.fetch_partition_window(topic, 0, cursor, 16) {
            Ok(window) => window
            Err(e) => fail("fetch: \{e}")
          }
          for entry in window.entries {
            if !bench_entry_ok(entry) {
              sequence_ok = false
            }
            cursor = entry.offset + 1L
            if entry.offset == base {
              seen = true
            }
          }
          if window.scan_end > cursor {
            cursor = window.scan_end
          }
          if !seen {
            tries += 1
            cli_sleep_ms(2)
          }
        }
        if !seen {
          fail(
            "produced record \{base} never became visible after \{tries} fetches",
          )
        }
        consumed += 1
        e2e_us.push(cli_now_us() - t0)
        ack_us.push(ack)
      }
      producer.close()
      consumer.close()
    }
    None => {
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      let log = match open_topic_log(data_dir, topic) {
        Ok(log) => log
        Err(e) => fail(e)
      }
      let mut cursor = log.high_watermark()
      for i = 0; i < samples; i = i + 1 {
        let t0 = cli_now_us()
        let base = match log.append([sample_record(cursor)]) {
          Ok(base) => base
          Err(e) => fail("append: \{e}")
        }
        let ack = cli_now_us() - t0
        if base != cursor {
          fail(
            "offset discontinuity: sample \{i} appended at \{base}, expected \{cursor}",
          )
        }
        produced += 1
        let entries = match log.read_bounded(cursor, 1, 0) {
          Ok(entries) => entries
          Err(e) => fail("read: \{e}")
        }
        if entries.length() == 1 && bench_entry_ok(entries[0]) {
          consumed += 1
        } else {
          sequence_ok = false
        }
        cursor += 1L
        e2e_us.push(cli_now_us() - t0)
        ack_us.push(ack)
      }
    }
  }
  let mode = if flags.get("remote") is Some(_) { "remote" } else { "local" }
  println(
    "benchmark latency topic=\{topic} mode=\{mode} samples=\{samples} record_size=\{size}",
  )
  println(
    "result samples=\{samples} produced=\{produced} consumed=\{consumed} sequence_ok=\{sequence_ok}",
  )
  println(stats_line("produce_ack_us", ack_us))
  println(stats_line("e2e_us", e2e_us))
  if !sequence_ok {
    cli_exit(1)
  }
  cli_exit(0)
}
