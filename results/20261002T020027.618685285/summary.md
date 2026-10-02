# Go vs Bun vs Node benchmark

CPU: AMD Ryzen 7 9800X3D 8-Core Processor  
Kernel: 7.0.0-29-generic  
Governor: performance  
Go: go version go1.27.1 linux/amd64  
Bun: 1.4.2  
Elysia: 2.0.0-beta.20  
Node: v26.10.0  
Express: 5.2.1  
better-sqlite3: 13.0.3  
wrk: wrk 4.2.0 [epoll] Copyright (C) 2012 Will Glozer

## Settings

```json
{"variants":"go go-4 bun elysia node bun-1","scenarios":"health feed post mixed","reps":3,"duration_s":20,"warmup_s":5,"connections":64,"server_cpus":"0-3,8-11","load_cpus":"4-7,12-15","memory":"16G","workers":8,"port":3100,"gomaxprocs":{"go":8,"go-4":4},"tuning":{"go":{"GOGC":"off","GOMEMLIMIT":"1536MiB"},"go-4":{"GOGC":"off","GOMEMLIMIT":"1536MiB"},"node":{"NODE_OPTIONS":"--max-semi-space-size=64"},"bun":{}}}
```

## Server metadata

```json
{"go":{"runtime":"go1.27.1","framework":"net/http","sqlite":"3.53.4"},"go-4":{"runtime":"go1.27.1","framework":"net/http","sqlite":"3.53.4"},"bun":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"},"elysia":{"runtime":"bun 1.4.2","framework":"elysia 2.0.0-beta.20","sqlite":"3.53.2"},"node":{"runtime":"node v26.10.0","framework":"express 5.2.1","sqlite":"3.53.4"},"bun-1":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"}}
```

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

Medians of 3 × 20s runs, 8 server threads, 64 connections. CPU is µs per request across all workers; memory is peak heap/stack across all workers (maximum across repetitions).

Errors: none
