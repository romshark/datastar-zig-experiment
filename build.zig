const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Datastar SDK: builds SSE payloads and parses request signals.
    const datastar = b.dependency("datastar", .{ .target = target, .optimize = optimize });
    const datastar_mod = datastar.module("datastar");

    // zt templating (vendored; see vendor/zt/PATCH.md). `addTemplates` transpiles
    // src/templates/*.zt to sibling *.zig; the generated code imports `zt_mod`.
    const zt_dep = b.dependency("zt", .{ .target = target, .optimize = optimize });
    const zt_mod = zt_dep.module("zt");
    const templates = zt.addTemplates(b, zt_dep, &.{
        b.path("src/templates/users.zt"),
    });

    // Root module bundles the vendored SQLite amalgamation, so no system SQLite
    // or headers are required.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, exe_mod);
    exe_mod.addImport("datastar", datastar_mod);
    exe_mod.addImport("zt", zt_mod);
    embedDatastarRuntime(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "zigvibe",
        .root_module = exe_mod,
    });
    // Templates must regenerate before anything that imports them compiles.
    exe.step.dependOn(templates);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests. main.zig references every source file from a `test` block,
    // so a single test binary covers the whole project.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(b, test_mod);
    test_mod.addImport("datastar", datastar_mod);
    test_mod.addImport("zt", zt_mod);
    embedDatastarRuntime(b, test_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.step.dependOn(templates);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// Expose the vendored Datastar runtime as an `@embedFile("datastar_js")`
/// import, so it can be compiled into the binary and served at /datastar.js.
/// (`@embedFile` cannot reach files outside the module's own directory.)
fn embedDatastarRuntime(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("datastar_js", .{
        .root_source_file = b.path("vendor/datastar/datastar.js"),
    });
}

/// Compile and link the vendored SQLite amalgamation into `mod`.
fn linkSqlite(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_ENABLE_STAT4",
        },
    });
}
