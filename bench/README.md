# bench

A benchmark runner that compares the [`go/`](../go/) and [`zig/`](../zig/) server implementations on the same workload.

It builds and runs each server one at a time (never concurrently), drives HTTP load with [k6](https://k6.io), and samples the server process tree's CPU and memory. On Linux with `perf` it also reports hardware counters.

## What it measures

Per implementation:

- **RPS** — requests per second (k6 `http_reqs` rate).
- **Latency** — average, p90, p99 of `http_req_duration` (k6).
- **CPU avg** — average CPU use of the server process tree during the load window, in percent of one core (may exceed 100 on multiple cores).
- **Mem avg / max** — average and peak resident memory of the process tree.
- **Cycles, instructions, cache misses, branch misses** — from `perf stat`, Linux only.

The CPU and memory figures cover the whole process tree, so the Go server's [sqinn](https://github.com/cvilsmeier/sqinn-go) child process (which runs SQLite) is included alongside the Go process; the Zig server runs SQLite in-process.

## Requirements

- [k6](https://k6.io), `jq`, `curl`, `awk`, `python3` — the runner.
- Go and Zig toolchains — to build the servers. Zig is built with `-Doptimize=ReleaseFast`; Go with the default optimized build.
- `perf` (Linux) — optional, for hardware counters. Absent elsewhere, those rows are omitted.

## Run

```sh
./bench.sh
```

Flags:

| Flag        | Default | Meaning                                  |
|-------------|---------|------------------------------------------|
| `-d`        | `10s`   | measured load duration                   |
| `-c`        | `50`    | concurrent connections (k6 VUs)          |
| `-w`        | `3s`    | warmup duration (discarded)              |
| `-p`        | `/`     | request path to benchmark                |
| `-o`        | —       | run only one target: `go` or `zig`       |
| `-P`        | —       | disable `perf` even when available       |
| `--go-dir`  | `../go` | path to the Go implementation            |
| `--zig-dir` | `../zig`| path to the Zig implementation           |

Example:

```sh
./bench.sh -d 30s -c 100
```

## How it works

For each target, in sequence:

1. Build the server binary.
2. Start it on a free port with a fresh, seeded SQLite database (wrapped in `perf stat` on Linux).
3. Wait until `GET /` returns 200.
4. Run a warmup load (discarded).
5. Run the measured load with k6 while sampling the process tree's memory; bracket the window with two precise CPU-time reads for the average.
6. Stop the server (SIGINT, so `perf` flushes its counters).
7. Parse k6's JSON summary, the samples, and `perf` output.

The workload is `GET /`, which renders the full page from a SQLite query — the servers' dynamic hot path. `GET` is used because it is idempotent and repeatable; the create/delete commands mutate state.

## Caveats

- **Same-machine load.** k6 and the server share the host, so k6 competes for CPU. Server CPU is attributed via process-tree sampling (not k6's), but heavy runs still see contention. Run on an otherwise idle machine and keep connections below core count for the cleanest numbers.
- **CPU-time resolution.** The average CPU is derived from cumulative CPU time. On macOS `ps` reports centisecond resolution; on Linux `ps cputime` is whole seconds, so prefer `perf` task-clock there for precision.
- **Implementation differences are real, not artifacts.** The Go server serializes database reads through a single sqinn connection; the Zig server opens a SQLite handle per connection. The benchmark measures those choices as-is.
