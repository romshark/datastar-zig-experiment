---
name: sqlite-zig
description: Standards for using SQLite from Zig via the vendored C amalgamation. Load when writing or reviewing database code — opening connections, threading/concurrency, prepared statements, transactions, or value binding. Covers matching the threading mode to the sharing pattern (the SQLITE_OPEN_NOMUTEX vs FULLMUTEX decision), WAL, busy_timeout, statement reuse, and bind lifetimes.
---

# SQLite from Zig

The database is the vendored amalgamation (`vendor/sqlite/`), compiled by `build.zig` and used through `@cImport`. Getting the threading and statement lifecycle right is where most of the performance and correctness lives.

## Threading mode: match it to the sharing pattern

SQLite has three threading modes:

| Mode | Guarantee | Cost |
|------|-----------|------|
| single-thread | no mutexing at all | fastest; unsafe across threads |
| **multi-thread** (`SQLITE_OPEN_NOMUTEX`) | a connection is safe to use from many threads **as long as no single connection is used by two threads at once** | one mutex-free connection per thread |
| **serialized** (`SQLITE_OPEN_FULLMUTEX`) | a **single** connection is safe to share across threads; SQLite serializes with per-connection mutexes | slowest; every call takes a mutex |

Two knobs select the mode:

- **Compile time:** `-DSQLITE_THREADSAFE=` sets the default — `0` single-thread, `1` **serialized** (SQLite's default), `2` **multi-thread**.
- **Per connection:** the `sqlite3_open_v2` flags `SQLITE_OPEN_NOMUTEX` / `SQLITE_OPEN_FULLMUTEX` override the compiled default for that connection.

Rule: **pick the mode that matches how the connection is shared.**

- **Connection-per-thread, never shared** (the standard design — each worker owns its own connection): open with `SQLITE_OPEN_NOMUTEX`. This is multi-thread mode: no per-call mutex, maximum concurrency. This is almost always what a threaded server wants.
- **One connection shared across threads:** requires serialized mode (`SQLITE_OPEN_FULLMUTEX`). Slower, and usually avoidable by giving each worker its own connection. Prefer connection-per-thread instead.

### The anti-pattern to avoid (present in this repo)

Reviewer's critique of the current code:

> Default mode is serialized, so it is safe to share. It is missing an open flag to take advantage of the higher-concurrency mode that can be enabled through thread-per-instance. Explicitly setting it to the slowest mode, then not making use of it and sharing the instance???

Concretely, the repo compiles `-DSQLITE_THREADSAFE=1` (serialized) **and** opens each connection without `SQLITE_OPEN_NOMUTEX`, so every connection pays for full per-call mutexing — yet each connection is used by exactly one worker thread and never shared. The serialization is pure overhead.

Fix: since every connection is used by a single thread, add `SQLITE_OPEN_NOMUTEX` to the open flags:

```zig
const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
```

This puts each connection in multi-thread mode: no mutex overhead, and it is still safe because no connection is touched by two threads. (Compiling `-DSQLITE_THREADSAFE=2` would set the same default globally, but the per-connection flag is the targeted, explicit fix and keeps the intent visible at the call site.)

Decision rule: **serialized/FULLMUTEX only if a single connection is genuinely shared across threads. Otherwise connection-per-thread + `SQLITE_OPEN_NOMUTEX`.**

## Concurrency and durability

- **WAL mode:** `PRAGMA journal_mode = WAL;` once per database allows concurrent readers alongside a single writer without readers blocking. For a read-heavy web server this is a large win over the default rollback journal (which blocks readers during a write). Pair with `PRAGMA synchronous = NORMAL;` (safe under WAL).
- **One writer at a time**, regardless of threading mode — WAL does not give concurrent writers. A second writer gets `SQLITE_BUSY`.
- **`busy_timeout`:** `sqlite3_busy_timeout(db, ms)` makes a busy connection wait and retry instead of failing immediately with `SQLITE_BUSY`. Set it on every connection.

## Prepared statements: compile once, reuse

`sqlite3_prepare_v2` compiles SQL — it is expensive relative to executing. Do not prepare a fresh statement per call in a hot path.

- Reuse a prepared statement across executions: `step` to run, then `sqlite3_reset` (re-run) and `sqlite3_clear_bindings` (drop old bound values) to reuse it.
- Cache the statements a worker uses (e.g. a struct of prepared statements per connection), created once at connection open.
- `sqlite3_finalize` each statement on connection teardown.

## Binding lifetimes

The last argument to `sqlite3_bind_text`/`_blob` is a destructor telling SQLite how to manage the bytes:

- `SQLITE_STATIC` — SQLite does **not** copy; the caller guarantees the bytes stay valid and unchanged until the statement is reset/finalized or the value is rebound. Use only for buffers that outlive the step.
- `SQLITE_TRANSIENT` — SQLite copies immediately; safe for temporaries. This is the correct default when the source may not outlive the call.

`SQLITE_TRANSIENT` is `(sqlite3_destructor_type)-1`, which Zig's translate-c cannot lower; re-declare `sqlite3_bind_text` with an opaque-pointer destructor and pass the sentinel, or wrap it.

## Transactions

Wrap batch writes in a single transaction:

```zig
try db.exec("BEGIN;");
errdefer db.exec("ROLLBACK;") catch {};
// ... many inserts on a reused, bound statement ...
try db.exec("COMMIT;");
```

Rationale: each autocommit statement fsyncs; one transaction fsyncs once. Batch inserts are orders of magnitude faster inside a transaction.

## Error mapping

Map result codes to distinct Zig errors; do not collapse to one. Callers branch on `SQLITE_BUSY` (retry/backoff), `SQLITE_CONSTRAINT` (validation — surface to the user), and `SQLITE_NOMEM` differently. Keep `errmsg`/`sqlite3_errmsg` reachable for diagnostics.

## Checklist

- [ ] Connection-per-thread with `SQLITE_OPEN_NOMUTEX` (not shared + serialized).
- [ ] `busy_timeout` set on every connection.
- [ ] WAL + `synchronous = NORMAL` if reads and writes are concurrent.
- [ ] Prepared statements reused (reset + clear_bindings), not re-prepared per call.
- [ ] Batch writes wrapped in a transaction with `errdefer ROLLBACK`.
- [ ] `SQLITE_TRANSIENT` for temporary bound values; `SQLITE_STATIC` only for outliving buffers.
- [ ] Distinct error mapping (Busy / Constraint / …), not a single catch-all.
