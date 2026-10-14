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
  /// True once the runner has asked this child to stop (its task is no longer
  /// desired); the reap loop then reaps it WITHOUT restarting, even on a
  /// non-zero exit.
  stopping : Bool
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
/// Whether a task is desired-running right now: enabled, and (when the runner
/// declares a worker) pinned to it or to "any"/absent. The single source for
/// both the initial selection and the periodic reconciliation.
fn task_desired(task : TaskDoc, worker : String?, want : String?) -> Bool {
  if !task.enabled {
    return false
  }
  let name_match = match want {
    None => true
    Some(w) => task.name == w
  }
  let worker_match = match worker {
    None => true
    Some(id) =>
      match task.target {
        None => true
        Some("any") => true
        Some(t) => t == id
      }
  }
  name_match && worker_match
}

///|
fn child_running(children : Array[Child], name : String) -> Bool {
  for c in children {
    if c.name == name && c.pid > 0 {
      return true
    }
  }
  false
}

///|
/// One beat: announce this worker and take the placement back. One request on
/// the control channel the runner already dials; the reply is the scheduler's
/// decision for THIS worker (decision 20 in reverse — the control plane never
/// dials the worker, the worker asks).
fn send_worker_beat(
  worker : String,
  control : String,
  data_dir : String,
  link : PeerLink,
) -> Result[@client.WorkerPlacement, String] {
  let payload = @client.encode_worker_beat(@client.WorkerBeat::{
    worker,
    address: runner_host(),
    data_dir,
  })
  match
    control_call_secure(control, @client.CMD_WORKER_HEARTBEAT, payload, link) {
    Ok(reply) => @client.decode_worker_placement(reply)
    Err(e) => Err(e)
  }
}

///|
/// The tasks that should be running right now, from one reconcile cycle's
/// inputs. Two shapes reduce to one list so the start/stop machinery below
/// has a single thing to act on:
///
///   * placement = None  — the local shape: the document decides, filtered by
///     `--worker`/`--name` (decisions 97/98, unchanged);
///   * placement = Some  — the scheduled shape: the control plane decided.
///     The names ARE the decision; the document is only consulted for
///     `--name` and as a sanity check on enabled, because the scheduler
///     already excludes disabled tasks and tasks pinned elsewhere.
fn desired_names(
  set : TaskSet,
  placement : @client.WorkerPlacement?,
  worker : String?,
  want : String?,
) -> Array[String] {
  let out : Array[String] = []
  for task in set.tasks {
    let ok = match placement {
      None => task_desired(task, worker, want)
      Some(p) => {
        let name_match = match want {
          None => true
          Some(w) => task.name == w
        }
        name_match && task.enabled && contains_string(p.tasks, task.name)
      }
    }
    if ok {
      out.push(task.name)
    }
  }
  out
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
  // `--worker <id>` is the scheduling half: the runner runs the tasks whose
  // `target` is this id (or "any"/absent). Without it, a runner runs everything
  // in its data dir — the single-node shape. A worker with nothing pinned to it
  // is a legitimate idle state, not an error: the scheduler may assign later.
  let worker = flags.get("worker")

  // A runner with BOTH --worker and --control is a SCHEDULED WORKER (P37-5b):
  // the control plane's scheduler decides what it runs, the worker's local
  // document is an adopted copy of the cluster's, and the beat keeps both
  // fresh. `--worker` alone stays the local placement filter (decision 97);
  // `--control` alone stays the single-node shape (decision 98). Neither of
  // those beats.
  let scheduled = match (worker, control) {
    (Some(_), Some(_)) => true
    _ => false
  }
  let link = peer_link(flags)
  // adoption bookkeeping for the cluster document — P11's machinery, reused
  // verbatim: assets first, then validate, then ONE write for the whole set
  let adoption = AdoptionState::{ failed_revision: 0L, reported: false, }
  // transition-only warnings: a warning every 500ms forever is how a log
  // stops being read; the first failure and the recovery are the events
  let mut beat_healthy = true
  // the last placement the scheduler gave this worker. Kept across a failed
  // beat (P11: a failed fetch keeps what runs); cleared when the control
  // plane answers that it has no opinion (no task set), which hands the
  // decision back to the local document.
  let mut placement : @client.WorkerPlacement? = None
  if scheduled {
    let id = match worker {
      Some(id) => id
      None => "" // unreachable: scheduled means worker is Some
    }
    let addr = match control {
      Some(addr) => addr
      None => "" // unreachable: scheduled means control is Some
    }
    match send_worker_beat(id, addr, data_dir, link) {
      Ok(first) => placement = if first.has_set { Some(first) } else { None }
      Err(e) =>
        // startup honesty: a scheduled worker that cannot ask its scheduler
        // must not guess from a possibly-stale local copy
        fail(
          "worker \{id}: the control plane at \{addr} did not answer the first beat (\{e}); not guessing what to run",
        )
    }
  }

  let set = load_task_set(data_dir)
  let chosen : Array[String] = desired_names(set, placement, worker, want)
  if chosen.length() == 0 {
    match worker {
      None =>
        fail(
          "runner: nothing to run under \{data_dir} (apply a task set first, or check --name)",
        )
      Some(id) => warn("runner: no tasks are pinned to worker \{id}; idle\n")
    }
  }

  // a runner is a long-lived process: a SIGTERM must stop its children
  // gracefully, not leave them orphaned
  cli_install_term_handler()

  let children : Array[Child] = []
  for task in set.tasks {
    if contains_string(chosen, task.name) {
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
      children.push(Child::{
        name: task.name,
        pid,
        restart: policy,
        stopping: false,
      })
    }
  }

  let mut last_sync_ms = 0L
  while true {
    if cli_term_requested() != 0 {
      warn("runner: signal received, stopping \{children.length()} task(s)\n")
      for c in children {
        let _ = cli_kill(c.pid, 15)
      }
      break
    }
    // reconcile every 500ms: what is desired right now, and what is running.
    // In the scheduled shape the beat asks first — the placement (and the
    // adopted document that backs it) is this cycle's desired state; in the
    // local shape the document alone decides (decision 98, unchanged).
    let now_ms = @env.now().reinterpret_as_int64()
    if now_ms - last_sync_ms >= 500L {
      last_sync_ms = now_ms
      if scheduled {
        let id = match worker {
          Some(id) => id
          None => "" // unreachable
        }
        let addr = match control {
          Some(addr) => addr
          None => "" // unreachable
        }
        match send_worker_beat(id, addr, data_dir, link) {
          Ok(p) => {
            if !beat_healthy {
              warn(
                "runner: the control plane answered again; placement resumes\n",
              )
              beat_healthy = true
            }
            placement = if p.has_set {
              if p.revision > local_cluster_revision(data_dir) {
                // the desired state moved: adopt the whole set, or keep
                // running what we have (P11 — a failed adoption warns once
                // per revision and never half-adopts)
                let _ = adopt_cluster_pipeline(
                  data_dir,
                  addr,
                  file_metadata_store(data_dir),
                  p.revision,
                  adoption,
                  link,
                )
              }
              Some(p)
            } else {
              None
            }
          }
          Err(e) =>
            if beat_healthy {
              warn(
                "runner: beat to \{addr} failed (\{e}); keeping the running tasks\n",
              )
              beat_healthy = false
            }
        }
      }
      let current = load_task_set(data_dir)
      let desired = desired_names(current, placement, worker, want)
      for i in 0..<children.length() {
        let c = children[i]
        if c.pid > 0 && !c.stopping && !contains_string(desired, c.name) {
          warn("runner: \{c.name} is no longer desired; stopping\n")
          let _ = cli_kill(c.pid, 15)
          children[i] = Child::{
            name: c.name,
            pid: c.pid,
            restart: c.restart,
            stopping: true,
          }
        }
      }
      for task in current.tasks {
        if contains_string(desired, task.name) &&
          !child_running(children, task.name) {
          let policy = match flag_restart {
            Some(r) => r
            None => task.restart
          }
          if policy != "never" && policy != "on-failure" && policy != "always" {
            warn(
              "runner: task \{task.name}: bad restart \{policy}; not started\n",
            )
          } else {
            let pid = spawn_task(cli, task.name, data_dir, control)
            if pid >= 0 {
              warn("runner: started \{task.name} (pid \{pid})\n")
              children.push(Child::{
                name: task.name,
                pid,
                restart: policy,
                stopping: false,
              })
            } else {
              warn("runner: could not spawn \{task.name}\n")
            }
          }
        }
      }
    }
    for i in 0..<children.length() {
      let c = children[i]
      let reap = cli_reap(c.pid)
      if reap > 0L {
        let code = reap - 1L
        if c.stopping {
          warn("runner: \{c.name} stopped (pid \{c.pid})\n")
          children[i] = Child::{
            name: c.name,
            pid: -1,
            restart: c.restart,
            stopping: false,
          }
        } else if should_restart(c.restart, code) {
          let pid = spawn_task(cli, c.name, data_dir, control)
          if pid >= 0 {
            warn("runner: \{c.name} exited (\{code}), restarted (pid \{pid})\n")
            children[i] = Child::{
              name: c.name,
              pid,
              restart: c.restart,
              stopping: false,
            }
          } else {
            warn("runner: \{c.name} exited (\{code}), respawn failed\n")
          }
        } else {
          warn(
            "runner: \{c.name} exited (\{code}), left stopped (restart=\{c.restart})\n",
          )
          children[i] = Child::{
            name: c.name,
            pid: -1,
            restart: c.restart,
            stopping: false,
          }
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
          children[i] = Child::{
            name: c.name,
            pid: -1,
            restart: c.restart,
            stopping: c.stopping,
          }
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
