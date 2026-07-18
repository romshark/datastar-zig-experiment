---
name: zig-engineering
description: Engineering standards for writing and reviewing Zig 0.16 in this repo. Load before creating or editing any .zig, build.zig, or build.zig.zon file, or reviewing Zig code. Covers concurrency (bounded, reused workers — not thread-per-task), per-request arena reuse, allocator discipline, error handling, and the 0.16 API changes that trip up generated code. For database code also load the `sqlite-zig` skill.
---

# Zig engineering (0.16)

Target: **Zig 0.16.0**. The standard library reorganized heavily in 0.15→0.16 (networking, I/O, threading, process entry). Code trained on older Zig will not compile. Verify APIs against the installed std source, not memory.

## Concurrency: bounded, reused workers

Rule: a server handles connections on a **fixed set of reused workers**, not one OS thread per connection.

Anti-pattern (spawn-per-connection):

```zig
while (true) {
    const conn = try listener.accept(io);
    const t = try std.Thread.spawn(.{}, handle, .{conn}); // new thread each time
    t.detach();                                            // unbounded, never reused
}
```

Why this is wrong: unbounded thread creation is a denial-of-service surface (one client can exhaust threads/RAM — each thread reserves a stack), creation/teardown cost is paid per request, and nothing is reused.

There is **no `std.Thread.Pool` in 0.16**. Two acceptable designs:

1. **Fixed worker pool (preferred here).** Spawn N worker threads once (`N ≈ cpu_count`). Each worker owns its per-thread resources (arena, DB connection) and loops: `accept()` on the shared listening socket, handle, repeat. The kernel load-balances `accept()` across workers. Resource use is capped at N.

2. **`std.Io` concurrency.** Run handlers via `io.async` / `io.concurrent` (+ `Io.Group`); the `Threaded` backend services them on a reused worker pool. Bound it explicitly with `Threaded.InitOptions.async_limit` / `concurrent_limit` — the default `concurrent_limit` is `.unlimited`, which reproduces the unbounded-thread problem. Note that `main` already receives an `Io` backed by such a pool (`std.process.Init.io`); spawning raw `std.Thread` alongside it bypasses that pool.

Either way: **cap concurrency** and **reuse workers**.

## Per-request arena, reused

Rule: each worker holds one long-lived arena and **resets** it after each request; it does not allocate a fresh arena per request.

Anti-pattern (fresh arena per request):

```zig
fn handle(req: *Request) !void {
    var arena = std.heap.ArenaAllocator.init(gpa); // new backing memory each request
    defer arena.deinit();                          // freed, then re-grown next time
    ...
}
```

Standard (reset, retaining capacity):

```zig
// Once per worker:
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
while (true) {
    const conn = try accept();
    handle(conn, arena.allocator()) catch {};
    _ = arena.reset(.retain_capacity); // keep the buffers, drop the contents
}
```

`ResetMode` (from `std.heap.ArenaAllocator`): `.retain_capacity` reuses the backing allocations, `.retain_with_limit` caps retained bytes, `.free_all` releases everything. Use `.retain_capacity` between requests; `.retain_with_limit` if a rare huge request would otherwise pin memory.

Rationale: steady-state request handling makes zero allocator calls to the backing allocator after warm-up. No per-request malloc/free churn, no fragmentation.

## Allocators

- Pass `std.mem.Allocator` as the first parameter of any function that allocates. No global allocator state.
- Choose by lifetime: **arena** for request-scoped batches freed together; a general-purpose/`c_allocator` as the arena's backing and for long-lived state.
- Place `defer x.deinit()` / `defer allocator.free(x)` immediately after acquisition.
- Document ownership in the doc comment: who frees the returned slice, and how (e.g. "free with `freeUsers`").
- Tests: use `std.testing.allocator` — it fails the test on leaks with a stack trace.

## Error handling

- Return explicit error sets, not `anyerror`. `anyerror` hides the failure modes and defeats exhaustive handling.
- `errdefer` for cleanup that must run only on the error path (partial initialization); `defer` for unconditional cleanup.
- Do not collapse distinct failures into one error when callers branch on them (e.g. keep `Busy` vs `Constraint` distinct — see `sqlite-zig`).
- `switch` on errors/enums exhaustively; add `else` only when the remaining cases are genuinely uniform.

## 0.16 API facts (verified against the installed std)

- **Networking:** `std.net` is gone. Use `std.Io.net` (`IpAddress`, `listen`, `accept`, `Stream`); most calls take an `io: Io`.
- **Reader/Writer:** non-generic `std.Io.Reader` / `std.Io.Writer` with embedded buffers. A buffered write is not sent until `flush()`. For chunked HTTP bodies, flush the body writer *and* the socket writer (`BodyWriter.flush` only flushes the latter).
- **Entry point:** `pub fn main(init: std.process.Init) !void` gives `init.io`, `init.gpa`, `init.arena`, and `init.minimal.args`.
- **Threading primitives:** `std.Thread.Mutex/Condition/sleep` are removed. Use `std.Io.Mutex` / `std.Io.Condition` (both take `io`) or `std.Io.sleep(io, duration, clock)`. `std.posix.read` exists; `std.posix.write` does not — write through the `Io` writer.
- **Containers:** initialize with `.empty` (e.g. `var list: std.ArrayList(T) = .empty;`) and pass the allocator per call (`list.append(allocator, x)`), or `.init` for stateful types. Not `.{}`.
- **`@typeInfo`:** fields are lowercase with keyword escaping: `.@"struct"`, `.@"union"`, `.pointer`, `.slice`.
- **Format methods:** `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`, invoked with `{f}`.

When unsure of a 0.16 API, read it under `$(dirname $(readlink -f $(which zig)))/../lib/zig/std/` rather than guessing.

## Verify

1. `zig build`
2. `zig build test`
3. Run the binary and exercise the changed path (not just tests).

## References

- nzrsky/zig-skills — Zig 0.16 skill with 57 std reference files: https://github.com/nzrsky/zig-skills
- 0xBigBoss/claude-code zig-best-practices — general Zig idioms: https://github.com/0xBigBoss/claude-code
- Production Zig to study: TigerBeetle, Ghostty, Bun, Zig std itself.
