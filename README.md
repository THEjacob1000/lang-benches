# Go vs Bun vs Node: HTTP + SQLite

A Linux benchmark comparing a well-written Go `net/http` server with raw `Bun.serve`, Elysia 2.0 beta, and a **Node baseline** using Express 5 and better-sqlite3. `bun-1` is a single-process reference; `bun`, `elysia`, and `node` run one worker process per allocated CPU thread (Node uses `node:cluster`). Toolchains are pinned in `mise.toml` (Go 1.27.1, Bun 1.4.2, Node 26.10.0).

The [server contract](docs/CONTRACT.md) defines the identical routes, response shapes, SQLite schema, pragmas, and prepared SQL. Scenarios cover health, user lookup, paginated posts, inserts, and a 60% user / 20% posts / 20% inserts mix. In the mix, reads hit users 1–5000 and inserts hit users 5001–10000, so a faster writer doesn't grow the posts lists it is also reading. The deterministic seed contains 10,000 users and 100,000 posts.

## Run

Requires Linux with a user systemd manager and delegated `cpuset`, CPU and memory controllers, mise, git, make, a C compiler, OpenSSL development headers, curl, jq, and taskset. The wrk 4.2.0 source build bundles LuaJIT.

```bash
bench/setup.sh
bench/check.sh
bench/run.sh
```

Setup builds wrk, installs frozen Bun dependencies and Node dependencies via `npm ci`, builds the Go executable, and creates `data/seed.db` if missing. To regenerate the deterministic seed explicitly, run `mise exec -- bun bench/seed.ts`. Conformance checks exercise successes, validation boundaries, oversized requests, unknown routes, foreign-key errors, lock timeout and internal DB errors, comparing all variants with Go. Runtime metadata and unspecified error bodies are normalized rather than requiring identical runtime names or unspecified payloads.

The runner writes environment metadata, each server's `/meta`, raw wrk JSON/output, cgroup metrics, and a Markdown summary under `results/<timestamp>/`. It removes disposable database files after each run. Regenerate a report with `bench/report.sh results/<timestamp>`.

## Fairness controls

- Every server is in its own systemd cgroup with the same CPU set, memory limit, and no swap. Go has `GOMAXPROCS` equal to allocated threads; clustered Bun and Node have the same number of worker processes.
- wrk is pinned to a disjoint CPU set, with one load thread per allocated load CPU. Default topology is the Ryzen 9800X3D: CPUs N and N+8 are SMT siblings. Adjust both sets for other machines.
- wrk uses a 10-second request timeout, above SQLite's 5-second busy timeout, so lock-wait successes are not silently excluded from latency histograms by wrk's 2-second default.
- Connections use the same WAL, synchronous, busy-timeout, foreign-key, cache and temporary-storage settings. Prepared statements and schema/SQL are shared by contract.
- Each repetition/scenario/variant starts with a fresh copy of the checkpointed seed database on tmpfs (`/dev/shm`). On disk, sustained concurrent writes left the JS clusters' WALs growing by gigabytes and the stalls came from kernel dirty-page writeback, which measures the SSD rather than the runtime. Warmup uses that copy before measurement; writes during warmup are therefore part of the measured database's starting state.
- Variants rotate by repetition (zero-based repetition r starts at variant index r modulo variant count). Two seconds between runs reduce immediate carryover.
- Three repetitions by default; the report independently takes medians for throughput, latency percentiles, total errors, and CPU seconds per 10,000 requests. Peak memory is the maximum across repetitions.
- CPU is the measured delta of cgroup `cpu.stat usage_usec`, including every worker. Memory is reported twice: peak anonymous memory (heap/stacks of every worker, sampled from `memory.stat` every 200 ms during measurement) and cgroup `memory.peak`, which also counts the tmpfs pages the server wrote (mostly the SQLite WAL), so it is not process memory. The `memory.peak` is reset after warmup when permitted; a failed reset is noted in the log and `memory_peak_reset: false` in metrics.
- No request logging or development mode. Versions, CPU model, kernel, governor, run settings, framework and bundled SQLite versions are recorded in `env.json`.

## Knobs

Set environment variables when calling `bench/run.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `VARIANTS` | `go bun elysia node bun-1` | Space-separated variants (`check.sh` also uses this; Go is always its conformance baseline) |
| `SCENARIOS` | `health user posts write mixed` | Space-separated workload list |
| `REPS` | `3` | Repetitions |
| `DURATION` | `20` | Measured seconds per run |
| `WARMUP` | `5` | Warmup seconds per run |
| `CONNS` | `64` | Concurrent wrk connections |
| `SERVER_CPUS` | `0-3,8-11` | Server CPU threads; determines worker count and GOMAXPROCS |
| `LOAD_CPUS` | `4-7,12-15` | Separate load-generator CPU threads |
| `SERVER_MEM` | `16G` | Server cgroup memory limit; tmpfs WAL pages count against it and can't be swapped |
| `DB_DIR` | `/dev/shm` | Where the per-run database copy lives |
| `PORT` | `3100` | Loopback port (`check.sh` also uses this) |

For example, `REPS=5 SCENARIOS="user mixed" bench/run.sh`.

## Known asymmetries

Go is one process with an in-process serialized writer pool (one connection, immediate transactions) and a reader pool sized to GOMAXPROCS. Bun and Node workers each own one SQLite connection and contend for writes through SQLite file locks and its busy handler. These are idiomatic implementations, not identical execution models.

Go, Bun, and better-sqlite3 can bundle different SQLite versions; `/meta` records the versions so results can be interpreted rather than attributing every difference to the HTTP runtime. Node, Express and better-sqlite3 package versions are also recorded in `env.json`. Go's garbage collector, JavaScriptCore's GC and V8's GC, scheduler, process overhead, connection caches, and memory accounting also differ. A health-only result measures HTTP overhead, not application or database throughput. Record errors alongside speed; overloaded runs are not equivalent successful work.

Every runtime runs with stock GC settings. Go's default `GOGC=100` on a tiny live heap collects very often; in a 5 s probe the `posts` scenario (~10 rows of ~1 KB bodies per response) went from ~37k to ~83k RPS with `GOGC=400`, while `user` barely moved. V8 has equivalent knobs (`--max-semi-space-size`) that aren't applied either; add `-E GOGC=…` to `start()` in `bench/run.sh` for a tuned comparison.

Bun clusters through `SO_REUSEPORT`, so the kernel hashes each of wrk's long-lived connections to a worker and the split is uneven and changes per run; `node:cluster` hands them out round-robin. That's how each runtime actually load-balances, so it's measured rather than corrected. Raising `CONNS` evens it out.

wrk is closed-loop: a connection stuck behind a stall sends nothing else, so a one-second stall shows up as a handful of slow samples rather than every request that would have arrived. Tail latency for the multi-writer JS variants, which wait in SQLite's busy handler under write contention, is therefore understated, not overstated.

## Results

Full run on 2026-10-02 (Ryzen 7 9800X3D, kernel 7.0, defaults above: 8 server threads, 64 connections, 3 × 20 s reps, medians). Full table with CPU, memory and wrk load: [`results/20261002T003319.313505247/summary.md`](results/20261002T003319.313505247/summary.md). The Node `write`/`mixed` rows were rerun after fixing its insert (see below); everything else is from the one run.

| OK RPS | health | user | posts | write | mixed |
|---|---:|---:|---:|---:|---:|
| bun | 1004.8k | 773.2k | 146.4k | 65.4k | 105.0k |
| elysia | 828.5k | 696.0k | 147.8k | 59.0k | 99.1k |
| go | 710.6k | 313.4k | 34.6k | 45.3k | 81.8k |
| node | 424.2k | 359.2k | 90.0k | 35.1k | 81.8k |
| bun-1 | 276.2k | 188.1k | 37.5k | 63.3k | 81.9k |

| p99 ms | health | user | posts | write | mixed |
|---|---:|---:|---:|---:|---:|
| bun | 4.54 | 4.14 | 4.24 | 611.77 | 27.14 |
| elysia | 7.23 | 4.07 | 3.03 | 443.63 | 28.78 |
| go | 1.50 | 1.72 | 7.83 | 7.15 | 13.57 |
| node | 3.79 | 3.06 | 4.17 | 54.50 | 23.59 |
| bun-1 | 0.57 | 1.39 | 2.96 | 2.30 | 1.56 |

- Clustered Bun wins on throughput for every scenario. Elysia costs 10–20% over raw `Bun.serve` on the light routes and nothing on `posts`.
- Go has the flattest tails everywhere and uses 10–30 MiB against Bun's 130–300 MiB and Node's ~500 MiB. Its weak spot is `posts` (~10 rows of ~1 KB each): it spends ~3× Bun's CPU per request, mostly in GC and `encoding/json` (see the `GOGC` note above).
- Writes: the clustered JS variants get throughput from 8 writers fighting over SQLite's lock, and pay for it with p99 in the hundreds of ms. Go's single in-process writer queue keeps p99 at 7 ms. Single-process Bun matches the cluster's write throughput with a 2 ms p99, because SQLite only ever takes one writer at a time anyway.
- No run had errors, and wrk never went above 60% CPU, so the load generator wasn't the cap.

Gotcha found along the way: `INSERT … RETURNING` read with Go's `QueryRow().Scan()` or better-sqlite3's `.get()` resets the statement before `SQLITE_DONE`. The commit then happens inside `sqlite3_reset`, which skips SQLite's WAL autocheckpoint, and the WAL grew ~1 GB/s under load. Both servers now step the statement to completion; Bun's `.get()` doesn't have the problem.
