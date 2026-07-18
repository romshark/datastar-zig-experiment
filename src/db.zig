//! Application data layer: the `users` table, first-run seeding, and queries.
//!
//! This sits on top of the low-level `sqlite` wrapper and speaks in terms of
//! the `User` domain type rather than raw columns.

const std = @import("std");
const sqlite = @import("sqlite.zig");

const Allocator = std.mem.Allocator;

pub const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    role: []const u8,
};

const schema =
    \\CREATE TABLE IF NOT EXISTS users (
    \\    id    INTEGER PRIMARY KEY,
    \\    name  TEXT NOT NULL,
    \\    email TEXT NOT NULL UNIQUE,
    \\    role  TEXT NOT NULL DEFAULT 'member'
    \\);
;

const seed_users = [_]struct { name: []const u8, email: []const u8, role: []const u8 }{
    .{ .name = "Ada Lovelace", .email = "ada@example.com", .role = "admin" },
    .{ .name = "Alan Turing", .email = "alan@example.com", .role = "admin" },
    .{ .name = "Grace Hopper", .email = "grace@example.com", .role = "member" },
    .{ .name = "Katherine Johnson", .email = "katherine@example.com", .role = "member" },
    .{ .name = "Dennis Ritchie", .email = "dennis@example.com", .role = "member" },
};

/// Ensure the schema exists and, if the `users` table is empty, populate it
/// with the built-in sample rows. Safe to call on every startup: an existing,
/// non-empty database is left untouched.
pub fn init(db: *sqlite.Db) !void {
    try db.exec(schema);
    if (try count(db) == 0) try seed(db);
}

fn count(db: *sqlite.Db) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM users;");
    defer stmt.deinit();
    _ = try stmt.step();
    return stmt.columnInt64(0);
}

fn seed(db: *sqlite.Db) !void {
    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch {};

    var stmt = try db.prepare("INSERT INTO users (name, email, role) VALUES (?1, ?2, ?3);");
    defer stmt.deinit();

    for (seed_users) |u| {
        try stmt.reset();
        try stmt.bindText(1, u.name);
        try stmt.bindText(2, u.email);
        try stmt.bindText(3, u.role);
        _ = try stmt.step();
    }

    try db.exec("COMMIT;");
}

/// Fetch all users ordered by id. The returned slice and every string it
/// references are allocated with `allocator`; free them with `freeUsers`.
pub fn allUsers(db: *sqlite.Db, allocator: Allocator) ![]User {
    var stmt = try db.prepare("SELECT id, name, email, role FROM users ORDER BY id;");
    defer stmt.deinit();

    var list: std.ArrayList(User) = .empty;
    errdefer freeList(&list, allocator);

    while (try stmt.step()) {
        try list.append(allocator, .{
            .id = stmt.columnInt64(0),
            .name = try allocator.dupe(u8, stmt.columnText(1)),
            .email = try allocator.dupe(u8, stmt.columnText(2)),
            .role = try allocator.dupe(u8, stmt.columnText(3)),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Insert a new user and return its assigned id. Returns `error.Constraint`
/// if the email is already taken (the `UNIQUE` constraint).
pub fn insertUser(db: *sqlite.Db, name: []const u8, email: []const u8, role: []const u8) !i64 {
    var stmt = try db.prepare("INSERT INTO users (name, email, role) VALUES (?1, ?2, ?3);");
    defer stmt.deinit();
    try stmt.bindText(1, name);
    try stmt.bindText(2, email);
    try stmt.bindText(3, role);
    _ = try stmt.step();
    return db.lastInsertRowId();
}

/// Delete the user with the given id. Deleting a non-existent id is a no-op.
pub fn deleteUser(db: *sqlite.Db, id: i64) !void {
    var stmt = try db.prepare("DELETE FROM users WHERE id = ?1;");
    defer stmt.deinit();
    try stmt.bindInt(1, id);
    _ = try stmt.step();
}

/// Free a slice previously returned by `allUsers`.
pub fn freeUsers(users: []const User, allocator: Allocator) void {
    for (users) |u| {
        allocator.free(u.name);
        allocator.free(u.email);
        allocator.free(u.role);
    }
    allocator.free(users);
}

fn freeList(list: *std.ArrayList(User), allocator: Allocator) void {
    for (list.items) |u| {
        allocator.free(u.name);
        allocator.free(u.email);
        allocator.free(u.role);
    }
    list.deinit(allocator);
}

test "init seeds a fresh database exactly once" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    try init(&db);
    try std.testing.expectEqual(@as(i64, seed_users.len), try count(&db));

    // A second init must not duplicate the seed data.
    try init(&db);
    try std.testing.expectEqual(@as(i64, seed_users.len), try count(&db));
}

test "allUsers returns seeded rows in id order" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try init(&db);

    const users = try allUsers(&db, std.testing.allocator);
    defer freeUsers(users, std.testing.allocator);

    try std.testing.expectEqual(seed_users.len, users.len);
    try std.testing.expectEqualStrings("Ada Lovelace", users[0].name);
    try std.testing.expectEqualStrings("admin", users[0].role);
    for (users, 0..) |u, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), u.id);
    }
}

test "insertUser adds a row and deleteUser removes it" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try init(&db);

    const id = try insertUser(&db, "Barbara Liskov", "barbara@example.com", "member");
    try std.testing.expectEqual(@as(i64, seed_users.len + 1), try count(&db));

    try deleteUser(&db, id);
    try std.testing.expectEqual(@as(i64, seed_users.len), try count(&db));

    // Deleting again is a harmless no-op.
    try deleteUser(&db, id);
    try std.testing.expectEqual(@as(i64, seed_users.len), try count(&db));
}

test "insertUser rejects a duplicate email" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try init(&db);

    try std.testing.expectError(
        sqlite.Error.Constraint,
        insertUser(&db, "Impostor", "ada@example.com", "member"),
    );
}
