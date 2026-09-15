# Fluvio 参考工作规约（对标参考系统）

> **来源与用途**：本文件原为 `~/workspace/fluvio/AGENTS.md`（2026-09-15 迁入 moonflux `docs/`）。它规定的是**在 Fluvio 参考仓库内作业**时的 agent 硬规则——进行架构研究、语义对照、互操作测试时遵循本规约，避免误读参照系而产生错误设计。**moonflux 自身的工作规则见仓库根 [`AGENTS.md`](../AGENTS.md)。**

Working guide for AI coding agents when working in the Fluvio reference repository. Fluvio is a Kubernetes-native,
distributed streaming platform written in Rust: control plane (Streaming Controller, SC),
data plane (Streaming Processing Units, SPUs), a custom binary wire protocol, a commit-log
storage engine, and WebAssembly-based programmable transforms (SmartModules).

This file encodes the architecture map, hard invariants, conventions, and the verification
workflow. Read it before making changes; prefer it over guessing from nearby code.

## 0. Ground rules

- **Smallest correct diff.** Match existing patterns; if a pattern seems wrong, propose the
  change separately — do not refactor opportunistically inside a feature/fix.
- **Hard invariants are hard.** Sections 4–6 (wire protocol, storage/replication, SmartModule
  ABI) are compatibility contracts. Never break them silently; version, test, and document.
- **Zero-copy paths stay zero-copy.** The data plane passes `Bytes`/file slices through
  untouched (`AsyncFileSlice`, `RawRecords`). Do not add copies on hot paths without a
  benchmark (`fluvio-benchmark`, criterion benches in `fluvio-storage`).
- **No new heavy dependencies** (especially on data-plane paths) without justification;
  prefer crates already in the root `[workspace.dependencies]`.
- **Async tests are not `#[tokio::test]`.** This repo tests async via `fluvio-future`
  fixtures. Follow the neighboring test's style.
- **Run the verification workflow (§9) before declaring a task done.** Feature-gate checks
  are part of CI; a change that compiles by default may fail in another feature combo.

## 1. Quick facts

| Item | Value |
| :--- | :--- |
| Crate version / platform version | `0.50.2` (root `Cargo.toml`) / `VERSION` file (platform, e.g. `0.18.2-dev-1`) |
| Toolchain | Rust **1.93.0** pinned (`rust-toolchain.toml`), edition 2024, **no MSRV declared** |
| Workspace | 55 members (~45 crates in `crates/`, examples, release tools, test connectors), ~127k LOC |
| Primary release targets | `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, `x86_64-apple-darwin`; Windows is CI check/test only. ARM/Android via `install.sh` + Zig cross-CC (`build-scripts/*-zig-cc`) |
| Data-plane wire format | **Custom binary codec in Kafka protocol *format*** (length-prefixed, varint, versioned structs). **Not** serde, **not** flatbuffers/protobuf. API keys are borrowed numbers only — there is **no Kafka wire compatibility** |
| WASM runtime | **wasmtime 38** + `wasi-common` 38 (WASI Preview1), fuel metering; classic **core-wasm** ABI — **no WIT/component model anywhere** |
| TLS | rustls first (aws-lc-rs default provider); SC/SPU retain openssl for cert APIs + optional `flv-tls-proxy` front proxy |
| Tests | ~570 `#[test]` functions, `fluvio-test` inventory-driven e2e harness, bats suites in `tests/cli/` |

## 2. Architecture map (where to look)

**Control plane — Streaming Controller (`crates/fluvio-sc`)**
- `src/start.rs` (Local / K8s / read-only modes) · `src/init.rs` (spawns one `MetadataDispatcher` per spec type) · `src/core/context.rs` (7 spec stores: Spu, Partition, Topic, SpuGroup, SmartModule, TableFormat, Mirror)
- `src/controllers/` — level-triggered reconciliation loops (`SpuController` heartbeat 90s expiry, `TopicController`, `PartitionController`/`PartitionReducer`, `scheduler/partition.rs` replica placement)
- `src/services/{public_api,private_api}` — client-facing admin API / SPU-facing registration + LRS
- `src/k8/` — real k8s operator objects; charts in `k8-util/helm/`

**Data plane — SPU (`crates/fluvio-spu`, largest crate)**
- `src/services/public/` — Produce, Fetch, StreamFetch, consumer-offset APIs, StartMirror
- `src/services/internal/` — SC + peer-SPU channels
- `src/control_plane/dispatcher.rs` — persistent SC connection (register, `UpdateReplica/UpdateSmartModule/UpdateMirror`, LRS reporting)
- `src/replication/{leader,follower}/` — replication state machines (see §5)
- `src/mirroring/{home,remote}/` — cluster-to-cluster mirroring
- `src/smartengine/` — SmartModule wiring into produce/fetch paths

**Storage (`crates/fluvio-storage`)** — `replica.rs` (`FileReplica`), `segments.rs`, `index.rs`/`mut_index.rs`, `checkpoint.rs`, `cleaner` (retention); `ReplicaStorage` trait (SPU is generic over it, memory impl for tests)

**Protocol & transport**
- `crates/fluvio-protocol` — codec (`Encoder`/`Decoder`), record/batch types; `crates/fluvio-protocol-derive` — proc macros (`Encoder`, `Decoder`, `RequestApi`, `FluvioDefault`)
- `crates/fluvio-socket` — `FluvioSocket`, `MultiplexerSocket` (correlation-ID keyed multiplexing over one TCP connection)
- `crates/fluvio-service` — `FluvioApiServer` + `api_loop!`/`call_service!` dispatch macros

**Schemas & metadata**
- `crates/fluvio-sc-schema` (public admin API keys), `crates/fluvio-spu-schema` (data API keys + constants), `crates/fluvio-controlplane` (SC↔SPU messages), `crates/fluvio-controlplane-metadata` (specs: topic/partition/spg/smartmodule/tableformat/mirror)
- `crates/fluvio-stream-model` — `MetadataItem`/`Spec` traits, local stores, `DualEpochMap` (epoch change-tracking for watch streams); `crates/fluvio-stream-dispatcher` — reconciliation dispatch
- **Canonical constants/defaults: `crates/fluvio-types/src/defaults.rs`** — check here before hardcoding any limit

**Client SDK (`crates/fluvio`)** — `fluvio.rs` facade, `producer/` (accumulator, batching, SipHash partitioning, `with_chain` client-side smartmodules), `consumer/` (StreamFetch streams, retry stream), `admin.rs`, `sync/` (client metadata stores), `metrics/`; wasm32 browser target uses WebSocket transport

**Tooling** — `fluvio-cli` (+ plugin mechanism `fluvio-<cmd>`), `fluvio-run` (sc/spu entry binary), `fluvio-cluster` (local/k8 provisioning, `check`, `upgrade`, `diagnostics`), `fluvio-benchmark`, `fluvio-channel`, `fluvio-version-manager`

**SmartModules** — `crates/fluvio-smartmodule` (guest SDK), `-derive`, `crates/fluvio-smartengine` (wasmtime host), `crates/smartmodule-development-kit` (`smdk`), `crates/cdk`; examples in `smartmodule/examples/`

**Connectors (framework only)** — `crates/fluvio-connector-common/-derive/-package/-deployer`; test connectors in `connector/`. **Production connectors (http/mqtt/kafka/…) live in external `fluvio-connectors` repos** — only the framework is here

**KV & offsets** — `crates/fluvio-kv-storage` (`LogBasedKVStorage`), `crates/fluvio-spu/src/kv/` (consumer offsets on the internal `consumer-offset` topic)

**Auth** — `crates/fluvio-auth` (Root / ReadOnly / Basic RBAC via x509 CN → role bindings)

## 3. Build, lint, test

GNU Make wraps cargo; see `Makefile` and `makefiles/{build,check,release,test}.mk`.

```bash
make build            # workspace build
make check            # checks incl. feature-gate combinations (CI parity)
make test             # unit tests
cargo check -p <crate>            # fast per-crate loop
cargo clippy -p <crate>           # lint (CI also runs clippy)
cargo fmt                         # rustfmt.toml
```

- **SmartModule dev loop**: `smdk generate/build/test/load`; `smdk build` targets **`wasm32-wasip1`** by default (`--nowasi` = legacy `wasm32-unknown-unknown`), profile `release-lto`. Engine tests load fixtures built from `smartmodule/examples/` — keep them building.
- **E2E**: `fluvio-test` harness (`crates/fluvio-test/src/tests/`: smoke, election, batching, consumer_offsets, longevity, stress, …) runs in `local` and `local-k8` modes; CI runs a subset.
- **CLI smoke tests**: bats suites under `tests/cli/` (cli, smdk, fvm, cdk, mirroring, read-only, partition, cross-version compatibility).
- **Cross builds**: musl/ARM use Zig as linker/CC via `build-scripts/`; release automation in `.github/workflows/{ci,ci_mac,release,cd_*}.yml`.

## 4. Wire protocol invariants (hard rules)

- Versioned structs use field attributes `#[fluvio(min_version = ..., max_version = ...)]`. **Never change the meaning of an existing version** — add a new version and gate behavior on the negotiated API version.
- API key spaces (do not reuse or renumber):
  - SC public admin: `ApiVersion = 18`, `Create/Delete/List/Watch/Mirroring/Update = 1001–1006` (`crates/fluvio-sc-schema/src/apis.rs`)
  - SPU public: `Produce = 0`, `Fetch = 1`, `StreamFetch = 1003`, consumer-offset APIs, `StartMirror = 2000+` (`crates/fluvio-spu-schema/src/server/api_key.rs`)
  - SC internal (`fluvio-controlplane/sc_api`), SPU internal `1001–1004` (`spu_api`), replication peer APIs
- Version constants you must bump when extending surfaces (examples): `crates/fluvio-spu-schema/src/server/stream_fetch.rs` (`ARRAY_MAP_WASM_API=15`, `SMART_MODULE_API=16`, `GENERIC_SMARTMODULE_API=17`, `CHAIN_SMARTMODULE_API=18`), `crates/fluvio-smartmodule/src/input.rs` (`SMARTMODULE_TIMESTAMPS_VERSION=22`).
- `MultiplexerSocket`: channels keyed by correlation ID (0 = streaming/shared); preserve streaming vs request/response semantics when adding channels.
- Raw bytes pass-through (`RawRecords`) is intentional — decode only what you must inspect.

## 5. Storage & replication invariants

- **HW vs LEO**: high watermark = committed (replicated) position; log end offset = tail. `ReadCommitted` reads ≤ HW; `ReadUncommitted` ≤ LEO. **Default consumer isolation is `ReadUncommitted`** (latency-first).
- **ISR/LRS**: leader maintains the live replica set; lagging followers are removed from LRS (losing election eligibility) but keep receiving records; HW = min replica LEO (`compute_hw`).
- **Replication is follower-pull**: followers open connections and send `SyncRequest`s via the fetch-stream API. Do not invert this or add push-based replication.
- **Leader election is SC-driven and two-phase**: SC nominates the least-lagging follower → the candidate SPU self-promotes and confirms. **There is no leader epoch/term in the data plane** — do not introduce Raft assumptions, epochs, or epoch-based log truncation.
- **Zero-copy**: `read_partition_slice` returns `AsyncFileSlice` served directly to sockets. Segments/index are append-only; sparse index only.
- **Consumer offsets**: KV records on internal topic `consumer-offset`, key = `(topic, partition, consumer_id)`. **There are no consumer groups** — do not add Kafka-style group semantics casually.
- Limits (`crates/fluvio-types/src/defaults.rs`): batch ≤ 2 MB (`STORAGE_MAX_BATCH_SIZE`), request ≤ 33 MB, retention default 7 days (min 10 s), segment 1 GiB, partition cap 100 GB, ISR min 1.
- Topic/partition `Spec`/`Status` carry resolution states (`Pending`, `InsufficientResources`, `Online`, …); update surface is intentionally minimal (`AddPartition`, `AddMirror` only).

## 6. SmartModule / WASM rules

- **ABI (classic core-wasm, versioned, tiny)**: guest exports `alloc(len)->i32`, `memory`, exactly one transform `(ptr, len, version)->i32` named `filter|map|filter_map|array_map|aggregate`, optional `init`/`look_back`; guest imports `copy_records(ptr,len)` (discovered by name) + WASI p1 stdio.
- **Execution**: per **batch**; modules chain through one wasmtime `Store` (`SmartModuleChainInstance`), fuel topped up per call (`DEFAULT_FUEL = i64::MAX/2`); memory cap default 1 GiB (`SPU_SMARTENGINE_STORE_MAX_BYTES`); **no wall-clock timeout** — fuel is the only runaway guard.
- **Invocation sites** (keep the semantics aligned across them): SPU fetch path (`services/public/stream_fetch.rs`), SPU produce path (`apply_smartmodules`), client-side producer (`TopicProducer::with_chain`), connector transforms (Source = in connector process, Sink = on SPU), topic dedup (compiled to a `Filter` invocation with `lookback`).
- **Changing the ABI or operators is a versioned surface change**: bump the API/format version constants, update `fluvio-smartmodule` (+derive), the host in `fluvio-smartengine`, `smdk`, and `smartmodule/examples`; run engine + vm/parity tests.
- Smartengine is feature-gated (`spu_smartengine`); a stub chain exists for builds without it — keep both compiling.
- Predefined modules resolve by `group/name@version` against SC-synced metadata; ad-hoc modules ship gzipped wasm in the request.

## 7. Control-plane & metadata conventions

- **Spec/Status pattern everywhere**; local stores use `DualEpochMap` for change detection that powers client watch streams — mutate via the provided APIs, not ad-hoc.
- **Controllers are level-triggered reconciliation loops** (K8s operator style): `select!` over store watchers + timers, error backoff, idempotent actions. New reconciliation logic belongs in a controller, not in request handlers.
- **K8s integration**: `k8-client` (external crate) with `memory_client` feature for tests; local mode uses `LocalMetadataStorage`. Tolerate `--local`, `--local-k8`, `--k8` modes.
- **Auth**: never bypass `fluvio-auth` checks in SC service handlers; new object types need `ObjectType` + policy entries.
- **Errors**: structured error enums via `thiserror`; API errors surface as `ApiError` with stable messages — treat message text as contract for tests.

## 8. External crates (not in this repo)

`fluvio-future`, `k8-client`/`k8-config`/`k8-types`/`k8-diff`, `fluvio-helm`, `flv-tls-proxy`,
`fluvio_ws_stream_wasm`, `fluvio-command` are Infinyon-maintained, versioned in the root
`Cargo.toml`. Async is abstracted through `fluvio-future` (wraps tokio) — check what the
neighboring crate uses before reaching for tokio APIs directly. SDF (stateful dataflows) is a
**separate project**, not in this repo. `fluvio-hub-protocol` defines types only; hub/cloud
CLIs are external plugins.

## 9. Verification workflow ("done" means)

- [ ] `cargo fmt` + `cargo clippy` clean for touched crates
- [ ] Unit tests added/updated; existing snapshot/parity expectations respected
- [ ] **Protocol change** → new version + version constants bumped + all schema crates updated + compat tests
- [ ] **Storage/hot-path change** → criterion benchmark comparison (`fluvio-storage` benches)
- [ ] **SmartModule change** → rebuild `smartmodule/examples`, run engine tests
- [ ] **Cross-component behavior** → run `fluvio-test` (local mode) and/or relevant bats suite
- [ ] Feature-gate check (`make check` parity) — smartengine on/off, tls variants
- [ ] User-visible change → `CHANGELOG.md` entry (keep-a-changelog format; `cliff.toml`)
- [ ] No new data-plane dependency without justification

## 10. Anti-patterns (do not)

- Add serde/flatbuffers/protobuf to data-plane paths; the data plane is the custom codec.
- Assume Kafka behaviors: no consumer groups, no exactly-once, no epoch truncation, default
  reads are UNCOMMITTED, mirrors are strictly one-directional.
- Mutate replica sets, HW, or leader roles outside `replication/` state machines and SC messaging.
- Hold locks across `.await`; block async workers with CPU work.
- Touch generated/versioned schema constants without the matching bump + tests.
- Claim Windows support beyond CI check/test; primary targets are Linux-musl and macOS.
- Rewrite upstream style (rustfmt, naming, module layout) to taste.

## 11. Further reading (in-repo)

`CONTRIBUTING.md`, `DEVELOPER.md`, `RELEASE.md`, `rfc/` (design proposals), `k8-util/helm/`
(charts + CRD samples), `CHANGELOG.md`, `deny.toml` (cargo-deny: licenses/advisories),
`cliff.toml`. Public docs: <https://www.fluvio.io/docs/fluvio/overview>.
