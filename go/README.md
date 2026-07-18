# zigvibe (Go port)

A Go rewrite of the [root zigvibe app](../README.md): the same users page — a live table backed by SQLite with add/delete driven by [Datastar](https://data-star.dev) — built on `net/http`, [templ](https://templ.guide) templates, and the [datastar-go](https://github.com/starfederation/datastar-go) SDK.

The behavior, routes, and CQRS-flavored read/write split are identical to the Zig version; see the [root README](../README.md) for the request-flow diagram and design rationale. This document covers only what differs in the Go implementation.

## Requirements

- **Go 1.25+** (uses `net/http` method-aware routing patterns, `//go:embed`, and a `tool` directive for templ).
- No C toolchain. SQLite runs in a child process; templ and the Datastar runtime are vendored or embedded.

## Dependencies

- **[templ](https://templ.guide)** — HTML templates compiled to Go. `users.templ` is the source of truth; `users_templ.go` is generated and committed.
- **[datastar-go](https://github.com/starfederation/datastar-go) v1.2.2** — server-side SDK. Reads request signals (`ReadSignals`) and formats SSE events (`PatchElements`/`PatchElementTempl`, `PatchSignals`, `ExecuteScript`).
- **[sqinn-go](https://github.com/cvilsmeier/sqinn-go) v2.1.5** — SQLite without cgo. It runs [Sqinn](https://github.com/cvilsmeier/sqinn) as a child process and talks to it over stdin/stdout; a prebuilt Sqinn binary for the host platform is embedded and extracted at launch.
- **[Datastar](https://data-star.dev) v1.0.2** — the browser runtime, embedded from `static/datastar.js` and served at `/datastar.js`.

## Run

```sh
go run .
# then open http://127.0.0.1:8080/
```

Optional arguments — listen address and database path:

```sh
go run . 0.0.0.0:9000 /tmp/users.db
# or build and run the binary:
go build -o zigvibe . && ./zigvibe 127.0.0.1:8080 users.db
```

Routes are identical to the [root README](../README.md#routes), plus `/app.css` and `/app.js` (the page's styles and theme script are served as static assets rather than inlined).

## Develop

The HTML lives in [templ](https://templ.guide) templates ([`users.templ`](users.templ)). Regenerate the Go after editing:

```sh
go tool templ generate   # or: templ generate
```

The generated `users_templ.go` is committed. Edit `users.templ`, regenerate, rerun `go run .`, and reload the browser.

## Test

```sh
go test ./...
```

Unit tests cover the data layer (schema + idempotent seeding, insert, delete, duplicate rejection), the email validator, content rendering and escaping, the `Hub`, HTTP routing, create validation (empty/invalid/duplicate), delete, and the initial SSE push over a real socket.

## Layout

| File            | Responsibility                                                    |
|-----------------|-------------------------------------------------------------------|
| `main.go`       | Entry point: parse args, open/seed DB, start the server           |
| `server.go`     | Routing, `Hub`, `/updates` SSE, command validation, static assets |
| `db.go`         | `users` schema, first-run seeding, queries, insert, delete        |
| `users.templ`   | The page + fragments as templ templates (source of truth for HTML) |
| `static/`       | Embedded assets: `datastar.js`, `app.css`, `app.js`               |

## Differences from the Zig version

- **Broadcast Hub.** The Zig `Hub` is an atomic version counter that each stream polls between sleeps. The Go `Hub` is a set of subscriber channels: `publish` wakes each open stream once, with no idle polling. A 15s keep-alive comment keeps intermediaries from closing idle streams; client disconnect ends a stream via request-context cancellation.
- **One SQLite connection.** sqinn is a single child process, so all requests share one connection serialized by the library's internal mutex, rather than a handle per connection.
- **Static assets.** The `<style>` and theme `<script>` blocks are served from `static/app.css` and `static/app.js` instead of being inlined in the page.
