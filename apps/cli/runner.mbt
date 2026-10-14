// SPDX-License-Identifier: Apache-2.0
// apps/cli runner: a resident supervisor that runs a task set as child
// processes (P37-5a).
//
// The runner is the "kubelet" half of the management plane: it does not decide
// WHAT to run — the applied task set document does — it only makes sure the
// named tasks ARE running, restarts them by policy, and on its own SIGTERM
// stops them gracefully. It reports nothing about runs itself: each child is a
// normal `pipeline run`, which already registers its run with `--control` and
// writes its own run-log, so `run list` and `task logs` see the same facts they
// always have.
//
// Why children are processes, not in-process calls: a task crash must not take
// the supervisor down with it, and a task that runs forever must be stoppable
// by signal without the runner needing a cooperative cancellation point inside
// someone else's loop.

///|
struct Child {
  name : String
  pid : Int32
  restart : String
}

///|
/// Builds the flattened argv `mf_cli_spawn` expects: strings separated by NUL,
/// the list ending with an empty entry (two consecutive NULs).
fn flat_argv(parts : Array[String]) -> Bytes {
  let buf = Buffer::Buffer()
  for part in parts {
    buf.write_bytes(@utf8.encode(part))
    buf.write_byte((0x00).to_byte())
  }
  buf.write_byte((0x00).to_byte())
  buf.to_bytes()
}

///|
fn spawn_task(
  cli : String,
  name : String,
  data_dir : String,
  control : String?,
) -> Int32 {
  let parts : Array[String] = [
    "pipeline", "run", "--name", name, "--data-dir", data_dir,
  ]
  let argv_parts = match control {
    None => parts
    Some(c) => {
      let more = parts
      more.push("--control")
      more.push(c)
      more
    }
  }
  cli_spawn(@utf8.encode(cli), flat_argv(argv_parts))
}

///|
/// The restart policy is the ONLY scheduling the runner does locally (the rest
/// is the control plane's job, P37-5b): `never` leaves an exited task stopped,
/// `on-failure` restarts only non-zero exits (default), `always` restarts any
/// exit. A clean `signal`/`exhausted` stop exits 0, which is why on-failure does
/// not respawn it.
fn should_restart(policy : String, exit_code : Int64) -> Bool {
  match policy {
    "never" => false
    "always" => true
    _ => exit_code != 0L
  }
}

///|
fn cmd_runner(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let data_dir = flags.require("data-dir")
  let cli = match flags.get("cli") {
    Some(p) => p
    None =>
      match @env.get_env_var("MOONFLUX_EXE") {
        Some(p) => p
        None =>
          fail(
            "runner needs --cli <path> (or MOONFLUX_EXE) so it can spawn task processes",
          )
      }
  }
  // `--restart` is an override for the whole run; without it, each task uses
  // the policy its own task-set document declares (default on-failure)
  let flag_restart = flags.get("restart")
  let control = flags.get("control")
  let want = flags.get("name")

  let set = load_task_set(data_dir)
  let chosen : Array[TaskDoc] = []
  for task in set.tasks {
    match want {
      None => chosen.push(task)
      Some(w) => if task.name == w { chosen.push(task) }
    }
  }
  if chosen.length() == 0 {
    fail(
      "runner: nothing to run under \{data_dir} (apply a task set first, or check --name)",
    )
  }

  // a runner is a long-lived process: a SIGTERM must stop its children
  // gracefully, not leave them orphaned
  cli_install_term_handler()

  let children : Array[Child] = []
  for task in chosen {
    let policy = match flag_restart {
      Some(r) => r
      None => task.restart
    }
    if policy != "never" && policy != "on-failure" && policy != "always" {
      fail(
        "task \{task.name}: restart must be never|on-failure|always (got \{policy})",
      )
    }
    let pid = spawn_task(cli, task.name, data_dir, control)
    if pid < 0 {
      fail("runner: could not spawn task \{task.name}")
    }
    warn("runner: started \{task.name} (pid \{pid})\n")
    children.push(Child::{ name: task.name, pid, restart: policy, })
  }

  while true {
    if cli_term_requested() != 0 {
      warn("runner: signal received, stopping \{children.length()} task(s)\n")
      for c in children {
        let _ = cli_kill(c.pid, 15)
      }
      break
    }
    for i in 0..<children.length() {
      let c = children[i]
      let reap = cli_reap(c.pid)
      if reap > 0L {
        let code = reap - 1L
        if should_restart(c.restart, code) {
          let pid = spawn_task(cli, c.name, data_dir, control)
          if pid >= 0 {
            warn("runner: \{c.name} exited (\{code}), restarted (pid \{pid})\n")
            children[i] = Child::{ name: c.name, pid, restart: c.restart, }
          } else {
            warn("runner: \{c.name} exited (\{code}), respawn failed\n")
          }
        } else {
          warn(
            "runner: \{c.name} exited (\{code}), left stopped (restart=\{c.restart})\n",
          )
          children[i] = Child::{ name: c.name, pid: -1, restart: c.restart, }
        }
      }
    }
    cli_sleep_ms(50)
  }

  // drain: give each child a bounded window to finish its graceful stop, then
  // reap; anything still alive gets SIGKILL. The runner never exits with a
  // live child it failed to account for.
  for _ in 0..<40 {
    let mut all_done = true
    for i in 0..<children.length() {
      let c = children[i]
      if c.pid > 0 {
        if cli_reap(c.pid) > 0L {
          children[i] = Child::{ name: c.name, pid: -1, restart: c.restart, }
        } else {
          all_done = false
        }
      }
    }
    if all_done {
      break
    }
    cli_sleep_ms(50)
  }
  for c in children {
    if c.pid > 0 {
      let _ = cli_kill(c.pid, 9)
    }
  }
  cli_exit(0)
}
