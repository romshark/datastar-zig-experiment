# zigvibe

**DISCLAIMER**: This is just a Zig vibe-coding experiment. The code is, with a very high
probability, a pile of 💩, so keep that in mind!

A small example web server in **Zig 0.16** that renders a table of users as
HTML, backed by **SQLite**, with add/delete driven by
[**Datastar**](https://data-star.dev). The database is created and seeded with
sample data on first run.

```
               commands (writes)
┌─────────────┐  POST /users/ · DELETE /users/1   ┌──────────────────┐   ┌───────────┐
│             │ ────────────────────────────────> │                  │   │           │
│ browser     │                                   │ std.http.Server  │──>│ SQLite DB │
│ + Datastar  │        read model (SSE)           │  (src/server.zig)│   │ users.db  │
│             │ <═══ GET /updates  (data-init) ══ │  + broadcast Hub │   │           │
└─────────────┘   fat morphs of #content          └──────────────────┘   └───────────┘
```

The design is **CQRS-flavored** — reads and writes travel on separate paths:

- On load, the page opens a long-lived **Server-Sent-Events** stream to
  `GET /updates` via Datastar's [`data-init`](https://data-star.dev/reference/attributes#data-init).
  That stream is the source of truth for the view: on connect, and after every
  change, it pushes a **"fat morph"** — the entire `#content` region re-rendered
  — which Datastar morphs into the DOM in place.
- **Commands** (`POST /users/`, `DELETE /users/{id}`) only *mutate* the database
  and then `publish()` to an in-process **`Hub`**. Every open `/updates` stream
  notices the new version and re-renders, so **all connected clients update at
  once** — the command response itself never carries the table.

The "Add user" and per-row "Delete" buttons open native `<dialog>` elements
**client-side** (no round-trip to open them). The create command validates the
submitted fields; on a problem it re-renders **just the dialog** (targeted by
`id`) with an inline error, keeping the entered values.

## Requirements

- **Zig 0.16.0** (uses the reorganized `std.Io` networking/reader/writer APIs and
  the `std.process.Init` entry point).
- A C toolchain — the build compiles the **vendored SQLite amalgamation** in
  [`vendor/sqlite/`](vendor/sqlite/), so no system SQLite is required.
- No network access at build time beyond the one-time `zig fetch` of the
  Datastar SDK (already pinned in `build.zig.zon`).

## Dependencies

- **[SQLite](https://sqlite.org)** — vendored amalgamation in `vendor/sqlite/`,
  compiled by `build.zig`.
- **[Datastar](https://data-star.dev) v1.0.2** — the browser runtime is vendored
  in `vendor/datastar/` and served at `/datastar.js` (embedded in the binary).
- **[datastar-zig](https://github.com/starfederation/datastar-zig)** — the
  server-side SDK (a `build.zig.zon` package dependency) that parses Datastar
  request signals and formats the SSE patch responses.

## Run

```sh
zig build run
# then open http://127.0.0.1:8080/
```

Optional arguments — listen address and database path:

```sh
zig build run -- 0.0.0.0:9000 /tmp/users.db
# or run the built binary directly:
./zig-out/bin/zigvibe 127.0.0.1:8080 users.db
```

Routes:

| Method    | Path                          | Response                                            |
|-----------|-------------------------------|-----------------------------------------------------|
| GET, HEAD | `/`, `/users`, `/index.html`  | `200` HTML page shell (boots the `/updates` stream) |
| GET       | `/updates`                    | `200` **SSE stream** — fat morphs of `#content`     |
| GET       | `/datastar.js`                | `200` the vendored Datastar runtime                 |
| POST      | `/users/`                     | create a user; publishes → stream refreshes         |
| DELETE    | `/users/{id}`                 | delete a user; publishes → stream refreshes         |
| GET       | anything else                 | `404` text                                          |
| other     | any                           | `405` text                                          |

`POST /users/` reads the submitted fields from Datastar signals (a JSON body)
and validates them: a blank name/email, an address failing the email check
(`^[^@\s]+@[^@\s]+\.[^@\s]+$`), or a duplicate email is rejected by re-rendering
the `#add-dialog` (a targeted element patch) with the error message — the table
is left untouched. On success the row is inserted, the change is published, and
the dialog is cleared and closed.

## Test

```sh
zig build test
```

Unit tests cover the SQLite wrapper, the data layer (schema + idempotent
seeding, insert, delete), the email validator, HTML rendering (including
escaping), the `Hub`, the SSE content event, and the HTTP request routing —
including create validation (empty/invalid/duplicate) and delete — all driven
over in-memory streams, so no socket is needed. The end-to-end SSE broadcast and
dialog behavior are verified separately in a real browser.

## Why HTTP/1.1 and not HTTP/2?

HTTP/2's benefits — multiplexing, header compression, single-connection reuse —
are almost entirely a *client ↔ edge* concern. In a typical deployment you
terminate HTTP/2 (and TLS) at a load balancer / reverse proxy / CDN and speak
plain HTTP/1.1 to the application server over the fast internal hop, where those
benefits don't apply. Backend HTTP/2 mainly earns its place for gRPC or
end-to-end streaming.

Zig's standard library implements HTTP/1.1 only (`std.http`); there is no
HTTP/2 in std, and third-party Zig HTTP/2 libraries are immature and tend to lag
new Zig releases. So this example uses the idiomatic, dependency-free
`std.http.Server` — which is also the realistic shape of a Zig app server
sitting behind a proxy.

## Layout

| File                 | Responsibility                                             |
|----------------------|------------------------------------------------------------|
| `src/main.zig`       | Entry point: parse args, open/seed DB, start the server    |
| `src/server.zig`     | Accept loop, routing, `Hub`, `/updates` SSE, command validation |
| `src/db.zig`         | `users` schema, first-run seeding, queries, insert, delete |
| `src/sqlite.zig`     | Thin idiomatic wrapper over the SQLite C API               |
| `src/html.zig`       | HTML rendering (page + table) with proper escaping         |
| `vendor/sqlite/`     | Vendored SQLite amalgamation (compiled by `build.zig`)     |
| `vendor/datastar/`   | Vendored Datastar browser runtime (served at `/datastar.js`)|

## Design notes

- **Read/write separation (CQRS).** The `/updates` SSE stream is the only thing
  that renders the table; commands just mutate and `publish()`. This keeps
  command handlers tiny, makes every client converge on the same state, and
  means "what the page looks like" lives in exactly one place.
- **Fat morphs.** The stream re-renders the whole `#content` region and lets
  Datastar's morph compute the minimal DOM change, rather than emitting
  fine-grained per-row add/remove patches. Simpler server code, and the toolbar
  and dialogs (which hold client-only state like the theme indicator) sit
  outside `#content` so a morph never clobbers them.
- **The broadcast Hub** is a lock-free monotonic version counter. Each stream
  remembers the version it last rendered and polls between short sleeps
  (`std.Io.sleep`); polling doubles as a heartbeat that detects dropped clients.
  A production build would swap this for an event/condition to avoid idle wakeups.
- **Threading.** Each accepted connection is handled on its own detached thread
  with its own SQLite connection (opened with a busy timeout) to the same file.
  SQLite is compiled with `SQLITE_THREADSAFE=1`.
- **Escaping.** All user-derived values are HTML-escaped in `src/html.zig`, so
  data in the database can never inject markup — including the values embedded
  in Datastar `data-*` attributes on each delete button.
- **Seeding is idempotent.** `db.init` creates the schema and only inserts the
  sample rows when the table is empty, so restarts don't duplicate data.
- **Client- vs server-side dialogs.** Opening/closing dialogs and copying a
  row's id into a signal are pure client-side Datastar expressions. The server
  only re-renders the add dialog when it has a validation error to report.
- **Light/dark theming.** Colors are declared once with the CSS `light-dark()`
  function under `color-scheme: light dark`, so the page follows the OS setting
  with no JavaScript. A small `matchMedia('(prefers-color-scheme: dark)')`
  listener additionally reacts to *runtime* changes: it mirrors the mode onto
  `<html data-theme>` (an override hook), updates the on-page indicator, and
  fires a `themechange` event — no reload required.
