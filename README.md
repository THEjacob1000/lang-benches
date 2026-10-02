# Go vs Bun vs Node: realistic HTTP APIs

A Linux benchmark of Go `net/http`, raw `Bun.serve`, Elysia 2.0 beta, and a Node baseline using Express 5 and better-sqlite3. `go` runs one process with `GOMAXPROCS` matching allocated threads; `go-4` runs that same executable with `GOMAXPROCS=4`, the same tuning and the full server CPU cgroup. `bun`, `elysia`, and `node` run one worker per allocated CPU thread; `bun-1` is a single-process reference with the full cgroup too. Toolchains are pinned in `mise.toml`.

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

Go defaults to `GOGC=off GOMEMLIMIT=1536MiB`: avoid frequent collection of a small live heap, while retaining a soft memory limit. Node uses `NODE_OPTIONS=--max-semi-space-size=64` to give short-lived request objects a larger young generation. Bun has no extra tuning. Settings are recorded in `env.json`.

`bench/pgo.sh` profiles a pprof-enabled Go build during a 35-second mixed workload after five seconds of warmup, captures a 30-second CPU profile into `servers/go/default.pgo`, then rebuilds the normal executable. Go automatically uses that profile on subsequent builds. This is fair profile-guided optimisation: JavaScript JITs already optimise from runtime profiles during warmup and measurement. Profiling uses the same cgroup, CPU allocation, tuning and fresh tmpfs seed as the runner, not a synthetic microbenchmark.

## Fairness controls

- Same cgroup CPU set, memory cap and no swap. Go's `GOMAXPROCS` and JS worker counts match allocated threads, except the explicit `go-4` and `bun-1` references.
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
| `VARIANTS` | `go go-4 bun elysia node bun-1` (`check.sh` always includes Go) |
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

Go serializes writers through one immediate-transaction connection and has a reader pool; JS workers own separate connections. SQLite still permits only one writer in `mixed`, so JS processes contend through file locks and the busy handler. The models are idiomatic, not identical.

Bun uses `SO_REUSEPORT`, hashing long-lived connections unevenly across workers; Node clusters distribute connections round-robin. More connections reduce imbalance. Go, Bun and better-sqlite3 may embed different SQLite builds; `/meta` records their versions. GC, schedulers and process/cache overhead also differ.

wrk is closed-loop: stalled connections stop sending requests, understating tail latency under write contention. Health measures HTTP overhead only. Always interpret successful work and errors together rather than comparing raw request counts alone.

## Results

Full run on 2026-10-02 (Ryzen 7 9800X3D, kernel 7.0, defaults above). Full report: [`results/20261002T020027.618685285/summary.md`](results/20261002T020027.618685285/summary.md).

| Scenario | Metric | Node/Express | Go | Go (4 threads) | Bun (8 procs) | Elysia (8 procs) | Bun (1 proc) |
|---|---|---:|---:|---:|---:|---:|---:|
| health | RPS | 535k (1.00×) | 959k (1.79×) | 597k (1.11×) | **1.34M (2.50×)** | 1.24M (2.32×) | 306k (0.57×) |
|  | p99 ms | 1.27 | 0.57 | 0.39 | 3.13 | 3.33 | **0.37** |
|  | CPU µs/req | 14.7 | 8.1 | 6.7 | 5.5 | 6.0 | **3.4** |
|  | Memory MiB | 536 | 1435 | 1436 | 130 | 302 | **15** |
| feed | RPS | 42k (1.00×) | **61k (1.43×)** | 42k (0.99×) | 55k (1.29×) | 54k (1.26×) | 11k (0.26×) |
|  | p99 ms | **3.05** | 3.66 | 12.6 | 3.43 | 3.33 | 9.10 |
|  | CPU µs/req | 189 | 130 | 94.8 | 143 | 146 | **92.6** |
|  | Memory MiB | 663 | 1585 | 1520 | 341 | 502 | **41** |
| post | RPS | 121k (1.00×) | 153k (1.26×) | 103k (0.85×) | **201k (1.66×)** | 186k (1.53×) | 47k (0.39×) |
|  | p99 ms | 1.40 | **1.21** | 1.93 | 1.84 | 2.48 | 2.26 |
|  | CPU µs/req | 65.7 | 51.3 | 38.7 | 39.1 | 42.0 | **22.0** |
|  | Memory MiB | 636 | 1585 | 1520 | 303 | 472 | **37** |
| mixed | RPS | 45k (1.00×) | **59k (1.33×)** | 43k (0.96×) | 57k (1.29×) | 57k (1.28×) | 14k (0.31×) |
|  | p99 ms | 7.71 | **5.51** | 10.5 | 6.79 | 6.74 | 7.02 |
|  | CPU µs/req | 155 | 126 | 92.5 | 118 | 121 | **73.9** |
|  | Memory MiB | 531 | 1484 | 1484 | 200 | 406 | **42** |

Medians of 3 × 20 s runs, 8 server threads, 64 connections, no errors. Go's memory is the `GOMEMLIMIT` doing its job: with `GOGC=off` the heap grows to ~1.5 GiB before collecting, so that column shows the configured budget, not what Go needs.
