//! Entry point: open (and seed) the database, then serve the users page over
//! HTTP/1.1.
//!
//! Usage: zigvibe [listen-address] [database-path]
//!   listen-address  default 127.0.0.1:8080
//!   database-path   default users.db (created and seeded on first run)

const std = @import("std");
const sqlite = @import("sqlite.zig");
const db = @import("db.zig");
const server = @import("server.zig");

const default_address = "127.0.0.1:8080";
const default_db_path = "users.db";

/// Zig 0.16 hands `main` a `std.process.Init` containing a ready-to-use `Io`
/// implementation, allocators, and the command-line arguments.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next(); // skip the executable name
    const address_text = args.next() orelse default_address;
    const db_path: [:0]const u8 = args.next() orelse default_db_path;

    const address = std.Io.net.IpAddress.parseLiteral(address_text) catch |err| {
        std.log.err("invalid listen address '{s}': {s}", .{ address_text, @errorName(err) });
        return err;
    };

    // Open the database once at startup to create/seed it before any request
    // is served. Each connection later opens its own handle to the same file.
    {
        var setup_db = try sqlite.Db.open(gpa, db_path);
        defer setup_db.close();
        try db.init(&setup_db);
        std.log.info("database ready at {s}", .{db_path});
    }

    try server.run(io, gpa, .{ .address = address, .db_path = db_path });
}

test {
    _ = @import("sqlite.zig");
    _ = @import("db.zig");
    _ = @import("html.zig");
    _ = @import("server.zig");
}
