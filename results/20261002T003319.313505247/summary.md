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
{"variants":"go bun elysia node bun-1","scenarios":"health user posts write mixed","reps":3,"duration_s":20,"warmup_s":5,"connections":64,"server_cpus":"0-3,8-11","load_cpus":"4-7,12-15","memory":"16G","workers":8,"port":3100}
```

## Server metadata

```json
{"go":{"runtime":"go1.27.1","framework":"net/http","sqlite":"3.53.4"},"bun":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"},"elysia":{"runtime":"bun 1.4.2","framework":"elysia 2.0.0-beta.20","sqlite":"3.53.2"},"node":{"runtime":"node v26.10.0","framework":"express 5.2.1","sqlite":"3.53.4"},"bun-1":{"runtime":"bun 1.4.2","framework":"bun","sqlite":"3.53.2"}}
```

## health

| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bun | 1004753.15 | 0.04 | 4.54 | 11.82 | 0 | 0.06 | 124.52 | 132.77 | 59.28 |
| elysia | 828473.14 | 0.05 | 7.23 | 29.13 | 0 | 0.07 | 293.30 | 308.43 | 54.67 |
| go | 710590.99 | 0.07 | 1.50 | 3.85 | 0 | 0.09 | 10.23 | 22.36 | 40.86 |
| node | 424218.99 | 0.12 | 3.79 | 13.37 | 0 | 0.15 | 556.04 | 593.73 | 27.73 |
| bun-1 | 276242.85 | 0.21 | 0.57 | 1.78 | 0 | 0.04 | 14.96 | 17.44 | 12.91 |

## mixed

| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bun | 105012.03 | 0.27 | 27.14 | 61.83 | 0 | 0.19 | 129.36 | 433.12 | 9.55 |
| elysia | 99056.47 | 0.30 | 28.78 | 62.78 | 0 | 0.22 | 297.83 | 581.52 | 9.38 |
| bun-1 | 81850.13 | 0.73 | 1.56 | 2.42 | 0 | 0.13 | 33.11 | 279.24 | 6.49 |
| node | 81799.89 | 0.42 | 23.59 | 72.40 | 0 | 0.35 | 484.49 | 740.34 | 7.56 |
| go | 81770.69 | 0.51 | 13.57 | 21.59 | 0 | 0.63 | 33.06 | 290.45 | 8.64 |

## posts

| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| elysia | 147814.20 | 0.42 | 3.03 | 6.46 | 0 | 0.51 | 438.45 | 455.81 | 15.62 |
| bun | 146409.10 | 0.38 | 4.24 | 9.64 | 0 | 0.50 | 261.36 | 272.13 | 15.58 |
| node | 89956.76 | 0.64 | 4.17 | 11.52 | 0 | 0.83 | 659.11 | 681.41 | 10.73 |
| bun-1 | 37502.84 | 1.61 | 2.96 | 4.71 | 0 | 0.28 | 32.38 | 36.31 | 3.75 |
| go | 34574.10 | 1.65 | 7.83 | 12.62 | 0 | 1.39 | 145.25 | 159.84 | 5.68 |

## user

| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bun | 773163.57 | 0.06 | 4.14 | 12.05 | 0 | 0.08 | 133.46 | 142.75 | 55.21 |
| elysia | 696012.26 | 0.07 | 4.07 | 9.94 | 0 | 0.09 | 304.74 | 319.80 | 50.16 |
| node | 359193.72 | 0.17 | 3.06 | 7.86 | 0 | 0.21 | 527.38 | 549.22 | 25.58 |
| go | 313439.05 | 0.16 | 1.72 | 4.42 | 0 | 0.19 | 14.40 | 24.95 | 24.24 |
| bun-1 | 188149.57 | 0.31 | 1.39 | 3.58 | 0 | 0.05 | 16.66 | 19.51 | 11.42 |

## write

| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bun | 65391.85 | 0.26 | 611.77 | 1102.65 | 0 | 0.17 | 136.09 | 1130.74 | 5.98 |
| bun-1 | 63295.18 | 0.89 | 2.30 | 3.50 | 0 | 0.16 | 34.09 | 1129.60 | 6.24 |
| elysia | 59022.62 | 0.27 | 443.63 | 811.48 | 0 | 0.19 | 292.36 | 1217.38 | 5.63 |
| go | 45336.51 | 1.29 | 7.15 | 10.64 | 0 | 0.40 | 26.52 | 758.58 | 5.10 |
| node | 35111.50 | 1.40 | 54.50 | 123.55 | 0 | 0.34 | 440.94 | 967.10 | 3.54 |

Rows are sorted by OK RPS: requests per second excluding non-2xx/3xx responses and timeouts. Numeric columns are medians across repetitions except memory and wrk CPU (maximum). Peak anon is the largest anonymous (heap/stack) memory of the whole cgroup, sampled every 200 ms during measurement. Peak cgroup is memory.peak and also counts page cache, which for write workloads is mostly the growing SQLite WAL. wrk CPU % near 100 means the load generator, not the server, capped throughput. If memory_peak_reset is false in a run, its cgroup peak includes startup and warmup.
