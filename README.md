# zigvibe

A vibe-coding experiment: the same small web app — a users table with add and
delete, backed by SQLite and driven by [Datastar](https://data-star.dev) —
implemented once in each language.

- [`go/`](go/) — Go 1.26 implementation
  - [Templ](https://templ.guide) for templating.
  - [sqinn-go](https://github.com/cvilsmeier/sqinn-go) for SQLite.
  - [datastar-go](https://github.com/starfederation/datastar-go) Datastar server SDK.
- [`zig/`](zig/) — Zig 0.16 implementation
  - [zt](https://github.com/lalinsky/zt) for templating.
  - vendored [SQLite](https://sqlite.org) amalgamation for SQLite.
  - [datastar-zig](https://github.com/starfederation/datastar-zig) Datastar server SDK.

See each folder's README for build and run instructions.
