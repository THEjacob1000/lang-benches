# Go vs Rust vs Bun vs Node: realistic HTTP APIs

A Linux benchmark of Go `net/http`, Rust (axum on tokio), raw `Bun.serve`, Elysia 2.0 beta, and a Node baseline using Express 5 and better-sqlite3. `go` runs one process with `GOMAXPROCS` matching allocated threads; `go-4` runs that same executable with `GOMAXPROCS=4`, the same tuning and the full server CPU cgroup. `rust` runs one process with `TOKIO_WORKER_THREADS` matching allocated threads. `bun`, `elysia`, and `node` run one worker per allocated CPU thread; `bun-1` is a single-process reference with the full cgroup too. Toolchains are pinned in `mise.toml`, plus `servers/rust/rust-toolchain.toml` for Rust.

SQLite is a near-zero-latency **data source**, not the subject of the comparison. Indexed lookups feed representative runtime work: HS256 JWT authentication, validation, shaping nested objects, deriving word counts, reading time, tags and excerpts, and JSON serialization. The [contract](docs/CONTRACT.md) fixes the SQL, pragmas, auth rules and byte-exact responses.

## Workloads and code standard

| Route | Work |
|---|---|
| `GET /health` | Static `ok`, without auth: HTTP overhead baseline |
| `GET /meta` | Runtime, framework and SQLite versions, without auth |
| `GET /feed?limit=N&cursor=C` | Authenticate, validate keyset pagination, join a viewer's feed, shape up to 50 posts and compute derived fields |
| `GET /posts/:id` | Authenticate, validate id, fetch post and 20 newest comments, derive fields and shape authors |
| `POST /posts/:id/comments` | Authenticate, validate JSON, increment comment count and insert in one immediate transaction |

Scenarios are `health`, `feed`, `post`, and `mixed` (70% feed, 20% post detail, 10% comments with a roughly 150-character body). Requests choose random users and posts. The deterministic seed has 10,000 users, 20 followees each, 100,000 posts with hashtags, 2 million fan-out feed items and 500,000 comments. Tokens are generated separately with a ten-year expiry.

Implementations must be idiomatic, clean, maintainable production code. Prepared statements, pools and native APIs are sensible optimisations; response/query caching, precomputed output, hand-rolled JSON writers, unsafe tricks and harness-input special cases are not.

## Run

Requires Linux, a user systemd manager with delegated cpuset/CPU/memory controllers, mise, git, make, a C compiler, OpenSSL development headers, curl, jq and taskset. wrk 4.2.0 bundles LuaJIT.

```bash
bench/setup.sh
bench/check.sh
bench/pgo.sh       # optional: collect a representative Go profile and rebuild
bench/run.sh
```

Setup installs frozen dependencies, builds wrk and Go (`-pgo=auto`), and seeds when the database or tokens are missing. Regenerate both with `mise exec -- bun bench/seed.ts`. Set the same `JWT_SECRET` for seeding and running; its development default is `gbb-dev-secret-change-me`. Conformance exercises routes, auth failures, pagination, validation boundaries, mutation effects, oversized bodies and writer lock timeout, and diffs every variant against Go. Only metadata, unspecified bodies and newly created timestamps are normalized.

The runner records environment settings, Go binary build settings and profile hash, `/meta`, raw wrk output, CPU/memory metrics and a summary under `results/<timestamp>/`. The summary combines scenarios in one table, with Node-relative throughput, latency, CPU/request and peak anonymous memory, plus error and load-generator saturation flags. Rebuild it with `bench/report.sh results/<timestamp>`.

## Runtime tuning

Go defaults to `GOGC=off GOMEMLIMIT=1536MiB`: avoid frequent collection of a small live heap, while retaining a soft memory limit. Rust uses mimalloc as its global allocator and a release profile with fat LTO and one codegen unit. Node uses `NODE_OPTIONS=--max-semi-space-size=64` to give short-lived request objects a larger young generation. Bun has no extra tuning. Settings are recorded in `env.json`.

`bench/pgo.sh` profiles Go and Rust (`PGO_TARGETS="go rust"` by default) under the same mixed workload after five seconds of warmup. Go captures a 30-second CPU profile from a pprof-enabled build into `servers/go/default.pgo` (committed, as Go recommends), which `go build` picks up automatically. Rust runs an instrumented build (`-Cprofile-generate`) and merges the result into `servers/rust/pgo/merged.profdata`, which `servers/rust/build.sh` applies with `-Cprofile-use`. That file is toolchain-specific and not committed; `bench/setup.sh` generates it when missing. This is fair profile-guided optimisation: JavaScript JITs already optimise from runtime profiles during warmup and measurement. Profiling uses the same cgroup, CPU allocation, tuning and fresh tmpfs seed as the runner, not a synthetic microbenchmark.

## Fairness controls

- Same cgroup CPU set, memory cap and no swap. Go's `GOMAXPROCS`, Rust's tokio worker threads and JS worker counts match allocated threads, except the explicit `go-4` and `bun-1` references.
- wrk uses a disjoint CPU set and one load thread per load CPU. Default topology pairs CPUs N and N+8 as SMT siblings; adjust for your machine.
- A ten-second wrk timeout exceeds SQLite's five-second busy timeout.
- Identical SQLite settings and prepared SQL. Writes step to completion, including `INSERT ... RETURNING`, to preserve WAL autocheckpointing; single-row reads use normal first-row APIs.
- Every run gets a fresh checkpointed seed copy on tmpfs; warmup writes remain in that copy. This avoids measuring disk writeback rather than runtime work.
- Variants rotate by repetition, with two seconds between runs. Reports use independent medians for throughput, latency, errors and CPU/request; memory is the maximum over repetitions.
- CPU includes all workers via cgroup usage. Anonymous memory is sampled every 200 ms; cgroup peak memory also includes written tmpfs/WAL pages. Peak is reset after warmup when allowed, with failures recorded.
- No request logging or development mode. Versions, CPU, kernel, governor, settings and SQLite versions are recorded.

## Knobs

| Variable | Default |
|---|---|
| `VARIANTS` | `go go-4 rust bun elysia node bun-1` (`check.sh` always includes Go) |
| `SCENARIOS` | `health feed post mixed` |
| `REPS`, `DURATION`, `WARMUP`, `CONNS` | `3`, `20` seconds, `5` seconds, `64` |
| `SERVER_CPUS`, `LOAD_CPUS` | `0-3,8-11`, `4-7,12-15` |
| `SERVER_MEM`, `DB_DIR`, `PORT` | `16G`, `/dev/shm`, `3100` |
| `GO_GOGC`, `GO_GOMEMLIMIT` | `off`, `1536MiB` |
| `NODE_TUNING` | `--max-semi-space-size=64` |
| `JWT_SECRET` | `gbb-dev-secret-change-me` |
| `PPROF_ADDR` | `127.0.0.1:6060` (`pgo.sh`) |

For example: `REPS=5 SCENARIOS="feed mixed" bench/run.sh`.

## Known asymmetries

Go and Rust each serialize writers through one immediate-transaction connection and use separate read connections; JS workers own separate connections. SQLite still permits only one writer in `mixed`, so JS processes contend through file locks and the busy handler. The models are idiomatic, not identical.

Bun uses `SO_REUSEPORT`, hashing long-lived connections unevenly across workers; Node clusters distribute connections round-robin. More connections reduce imbalance. Go, Rust, Bun and better-sqlite3 embed different SQLite builds; `/meta` records their versions. Rust's bundled SQLite (libsqlite3-sys) is built with `-USQLITE_ENABLE_MEMORY_MANAGEMENT -DSQLITE_DEFAULT_MEMSTATUS=0` in `servers/rust/.cargo/config.toml`: libsqlite3-sys enables memory management by default, which makes every connection in the process share one mutex-guarded page cache, and memory statistics add a global mutex on each allocation. mattn and better-sqlite3 don't share the page cache, so leaving it on cost Rust over half its `post` throughput for a SQLite build difference rather than anything Rust does. Go's mattn build keeps `MEMSTATUS` on because the flag measured within 1% there. GC, schedulers and process/cache overhead also differ.

wrk is closed-loop: stalled connections stop sending requests, understating tail latency under write contention. Health measures HTTP overhead only. Always interpret successful work and errors together rather than comparing raw request counts alone.

## Results

Full run on 2026-10-02 (Ryzen 7 9800X3D, kernel 7.0, defaults above). The Rust column was rerun after fixing its SQLite build flags (above), with the same settings on the same machine; every other column is from the one run.

| Scenario | Metric | Node/Express | Go | Go (4 threads) | Rust | Bun (8 procs) | Elysia (8 procs) | Bun (1 proc) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| health | RPS | 529k (1.00×) | 958k (1.81×) | 592k (1.12×) | 932k (1.76×) | **1.30M (2.46×)** | 1.19M (2.25×) | 303k (0.57×) |
|  | p99 ms | 1.51 | 0.58 | 0.40 | **0.26** | 3.61 | 3.69 | 0.40 |
|  | CPU µs/req | 15.0 | 8.2 | 6.7 | 4.2 | 5.6 | 6.1 | **3.4** |
|  | Memory MiB | 532 | 1436 | 1435 | 17 | 133 | 312 | **16** |
| feed | RPS | 42k (1.00×) | 61k (1.44×) | 40k (0.95×) | **89k (2.11×)** | 54k (1.28×) | 51k (1.21×) | 11k (0.26×) |
|  | p99 ms | 3.16 | 3.67 | 11.0 | **1.37** | 3.66 | 4.22 | 8.94 |
|  | CPU µs/req | 189 | 130 | 99.4 | **89.1** | 144 | 151 | 94.7 |
|  | Memory MiB | 649 | 1585 | 1520 | 154 | 341 | 493 | **42** |
| post | RPS | 119k (1.00×) | 144k (1.21×) | 102k (0.86×) | **293k (2.47×)** | 193k (1.63×) | 174k (1.47×) | 46k (0.39×) |
|  | p99 ms | 1.50 | 1.76 | 1.95 | **0.92** | 2.63 | 3.49 | 2.53 |
|  | CPU µs/req | 67.0 | 52.4 | 39.0 | 25.4 | 40.0 | 43.2 | **22.4** |
|  | Memory MiB | 637 | 1585 | 1521 | 158 | 305 | 474 | **37** |
| mixed | RPS | 44k (1.00×) | 58k (1.32×) | 39k (0.90×) | **95k (2.16×)** | 57k (1.30×) | 56k (1.28×) | 14k (0.31×) |
|  | p99 ms | 7.32 | **5.71** | 11.6 | 5.73 | 6.73 | 7.07 | 7.81 |
|  | CPU µs/req | 158 | 127 | 99.4 | 82.7 | 118 | 121 | **75.8** |
|  | Memory MiB | 527 | 1484 | 1483 | 82 | 199 | 402 | **41** |

Medians of 3 × 20 s runs, 8 server threads, 64 connections, no errors. Go's memory is the `GOMEMLIMIT` doing its job: with `GOGC=off` the heap grows to ~1.5 GiB before collecting, so that column shows the configured budget, not what Go needs.
