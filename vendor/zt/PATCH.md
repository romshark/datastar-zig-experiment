# Vendored zt (patched for Zig 0.16)

Upstream: https://github.com/lalinsky/zt (experimental, no releases).

Upstream targets Zig 0.15.x and does not build on this project's Zig 0.16
toolchain. The **only** change from upstream is `src/main.zig` (the build-time
`zt-compile` CLI driver), ported to the 0.16 std APIs:

- `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`
- `std.process.argsAlloc` → `std.process.Init` / `args.toSlice()`
- `std.fs.cwd().readFileAlloc`/`writeFile` → `std.Io.Dir` + `Io`-passing forms

The parser, codegen, and runtime already used the new `std.Io.Writer` and are
unmodified. Generated templates render `writeAll`/`writeEscaped` into a
`*std.Io.Writer`, matching the rest of this codebase.

When upstream gains 0.16 support, re-sync and drop this patch.
