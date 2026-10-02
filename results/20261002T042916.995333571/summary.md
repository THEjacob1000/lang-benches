# Go vs Rust vs Bun vs Node benchmark

CPU: AMD Ryzen 7 9800X3D 8-Core Processor  
Kernel: 7.0.0-29-generic  
Governor: performance  
Go: go version go1.27.1 linux/amd64  
Rust: rustc 1.99.0 (b940084d7 2026-09-28)  
Bun: 1.4.2  
Elysia: 2.0.0-beta.20  
Node: v26.10.0  
Express: 5.2.1  
better-sqlite3: 13.0.3  
wrk: wrk 4.2.0 [epoll] Copyright (C) 2012 Will Glozer

## Settings

```json
{"variants":"go go-4 rust bun elysia node bun-1","scenarios":"health feed post mixed","reps":3,"duration_s":20,"warmup_s":5,"connections":64,"server_cpus":"0-3,8-11","load_cpus":"4-7,12-15","memory":"16G","workers":8,"port":3100,"gomaxprocs":{"go":8,"go-4":4},"tokio_worker_threads":{"rust":8},"tuning":{"go":{"GOGC":"off","GOMEMLIMIT":"1536MiB"},"go-4":{"GOGC":"off","GOMEMLIMIT":"1536MiB"},"rust":{"allocator":"mimalloc"},"node":{"NODE_OPTIONS":"--max-semi-space-size=64"},"bun":{}}}
```

## Server metadata

```json
{"go":{"runtime":"go1.27.1","framework":"net/http","sqlite":"3.53.4"},"go-4":{"runtime":"go1.27.1","framework":"net/http","sqlite":"3.53.4"},"rust":{"runtime":"rust 1.99.0","framework":"axum 0.8.9","sqlite":"3.53.2"},"bun":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"},"elysia":{"runtime":"bun 1.4.2","framework":"elysia 2.0.0-beta.20","sqlite":"3.53.2"},"node":{"runtime":"node v26.10.0","framework":"express 5.2.1","sqlite":"3.53.4"},"bun-1":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"}}
```

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

Medians of 3 × 20s runs, 8 server threads, 64 connections. CPU is µs per request across all workers; memory is peak heap/stack across all workers (maximum across repetitions).

Errors: none
