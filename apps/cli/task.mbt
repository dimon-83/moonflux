// SPDX-License-Identifier: Apache-2.0
// apps/cli task: the lifecycle command surface (P37-5a, decision 95).
//
// These two verbs are READ-ONLY projections of facts the platform already
// keeps: `task status` is `run list` (the run registry is the truth about what
// is running/stopped/offline), and `task logs` is the run-log topic — the
// structured events (run-start / batch / run-stop) a run wrote. Neither invents
// a second source of truth, and neither adds a port or a new command semantics
// (the "no second control plane" rule from the P37 ticket).
//
// `task start`/`task stop` are the WRITE half and belong to scheduling
// (P37-5b): they change the desired state in the task-set document, which the
// control plane reconciles. They are not here yet on purpose — a read-only
// surface can ship before the write surface exists, but not the other way
// round.

///|
fn cmd_task(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    usage()
  }
  match argv[0] {
    "status" => run_list(argv[1:argv.length()].to_owned())
    "schedule" => schedule_list(argv[1:argv.length()].to_owned())
    "start" => task_set_enabled(argv[1:argv.length()].to_owned(), true)
    "stop" => task_set_enabled(argv[1:argv.length()].to_owned(), false)
    "logs" => {
      let flags = parse_flags(argv[1:argv.length()].to_owned())
      let name = flags.require("name")
      // The child's own stderr FIRST, then the run-log events, because the two
      // are different evidence: the run-log says what the run decided (started,
      // batches, stopped), the process's stderr says what the platform printed
      // while doing it. `cmd_consume` exits the process, so anything printed
      // after it would never appear — hence this order.
      let data_dir = flags.get("data-dir") |> unwrap_or(".moonflux-data")
      let stderr_path = task_stderr_path(data_dir, name)
      match @fs.read_file(stderr_path) {
        Ok(bytes) => {
          let text = @utf8.decode_lossy(bytes[0:bytes.length()])
          if text.length() > 0 {
            println("── \{name} child stderr (\{stderr_path}) ──")
            println(text)
            println("── run-log events (\{run_log_topic(name)}) ──")
          }
        }
        Err(_) => ()
      }
      let rest : Array[String] = ["--topic", run_log_topic(name), "--from", "0"]
      match flags.get("remote") {
        Some(r) => {
          rest.push("--remote")
          rest.push(r)
        }
        None => ()
      }
      match flags.get("data-dir") {
        Some(d) => {
          rest.push("--data-dir")
          rest.push(d)
        }
        None => ()
      }
      if flags.get("follow") is Some(_) {
        rest.push("--follow")
      }
      cmd_consume(rest)
    }
    _ => usage()
  }
}
