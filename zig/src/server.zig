//! A small HTTP/1.1 server built on `std.http.Server` and the `std.Io`
//! networking layer, with a CQRS-flavored Datastar UI.
//!
//! Reads and writes are separated:
//!   * The **read model** is a long-lived Server-Sent-Events stream at
//!     `GET /updates` (opened by the page via `data-init`). Whenever the data
//!     changes it pushes a "fat" morph of the whole `#content` region.
//!   * **Commands** (`POST /users/`, `DELETE /users/{id}`) mutate the database
//!     and then `publish()` to a shared `Hub`, which wakes every open stream so
//!     all connected clients re-render. Commands themselves return only UI
//!     feedback (e.g. a re-rendered dialog on a validation error), never the
//!     table.
//!
//! Connections are served by a fixed pool of worker threads (bounded, reused —
//! not one spawned thread per connection). Each worker owns its own database
//! connection and request arena and loops accept -> serve -> reset. A shared
//! `Hub` (a lock-free version counter) coordinates the streams.
//!
//! A long-lived `/updates` stream occupies its worker for its lifetime, so the
//! pool size bounds the number of concurrent clients. A server expecting many
//! idle streaming connections would use evented I/O instead.

const std = @import("std");
const datastar = @import("datastar");
const sqlite = @import("sqlite.zig");
const db = @import("db.zig");
const html = @import("html.zig");

const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.server);

/// The Datastar runtime, compiled into the binary and served at /datastar.js.
const datastar_js = @embedFile("datastar_js");

const header_buffer_len = 16 * 1024;
const send_buffer_len = 32 * 1024;
const stream_buffer_len = 16 * 1024;

/// The subset of Datastar signals we read when creating a user.
const CreateSignals = struct {
    name: []const u8 = "",
    email: []const u8 = "",
    role: []const u8 = "member",
};

/// Monotonic version counter broadcast to every open `/updates` stream. A
/// stream stores the version it last rendered and polls this counter; polling
/// also drives the stream heartbeat and disconnect check.
pub const Hub = struct {
    version: std.atomic.Value(u64) = .{ .raw = 1 },

    /// Signal that the data changed.
    pub fn publish(self: *Hub) void {
        _ = self.version.fetchAdd(1, .release);
    }

    /// The current data version.
    pub fn current(self: *Hub) u64 {
        return self.version.load(.acquire);
    }
};

/// How long a `/updates` stream sleeps between checks of the hub version.
const poll_interval = std.Io.Duration.fromMilliseconds(200);
/// After this many idle polls (~15s) a stream emits a keep-alive comment.
const heartbeat_polls = 75;

pub const Options = struct {
    address: net.IpAddress,
    /// Path to the SQLite database file (each worker opens its own handle).
    db_path: [:0]const u8,
};

/// Bind, listen, and serve connections on a fixed worker pool until the process
/// is terminated.
pub fn run(io: Io, gpa: Allocator, options: Options) !void {
    var hub: Hub = .{};

    var address = options.address;
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const cpu = std.Thread.getCpuCount() catch 4;
    const worker_count = std.math.clamp(cpu * 4, 8, 128);
    log.info("listening on http://{f} ({d} workers)", .{ options.address, worker_count });

    const workers = try gpa.alloc(std.Thread, worker_count);
    defer gpa.free(workers);
    for (workers) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ io, &listener, gpa, options.db_path, &hub });
    }
    for (workers) |t| t.join();
}

/// Worker loop: own one database connection and one request arena for the
/// worker's lifetime, and handle accepted connections one at a time. The kernel
/// load-balances `accept` across workers on the shared listening socket.
fn worker(io: Io, listener: *net.Server, gpa: Allocator, db_path: [:0]const u8, hub: *Hub) void {
    var conn_db = sqlite.Db.open(gpa, db_path) catch |err| {
        log.err("worker: cannot open database: {s}", .{@errorName(err)});
        return;
    };
    defer conn_db.close();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var recv_buffer: [header_buffer_len]u8 = undefined;
    var send_buffer: [send_buffer_len]u8 = undefined;

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return, // shutdown
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        serveConnection(io, stream, &conn_db, hub, &arena, &recv_buffer, &send_buffer) catch |err| switch (err) {
            error.WriteFailed, error.ReadFailed => {}, // client hung up; nothing to do
            else => log.warn("connection error: {s}", .{@errorName(err)}),
        };
        stream.close(io);
        _ = arena.reset(.retain_capacity);
    }
}

fn serveConnection(
    io: Io,
    stream: net.Stream,
    conn_db: *sqlite.Db,
    hub: *Hub,
    arena: *std.heap.ArenaAllocator,
    recv_buffer: []u8,
    send_buffer: []u8,
) !void {
    var reader = stream.reader(io, recv_buffer);
    var writer = stream.writer(io, send_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    try serve(io, &http_server, conn_db, hub, arena);
}

/// Read and answer requests until the connection should no longer be kept
/// alive, resetting the arena after each. Transport-agnostic: works over any
/// reader/writer, including the in-memory pair used by the tests.
pub fn serve(io: Io, http_server: *std.http.Server, conn_db: *sqlite.Db, hub: *Hub, arena: *std.heap.ArenaAllocator) !void {
    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        const keep_alive = try handleRequest(io, &request, conn_db, hub, arena);
        _ = arena.reset(.retain_capacity);
        if (!keep_alive) return;
    }
}

/// Route and answer a single request. Returns whether the connection should be
/// kept alive for a subsequent request.
fn handleRequest(io: Io, request: *std.http.Server.Request, conn_db: *sqlite.Db, hub: *Hub, arena: *std.heap.ArenaAllocator) !bool {
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    switch (request.head.method) {
        .GET, .HEAD => {
            if (std.mem.eql(u8, path, "/updates")) {
                if (request.head.method != .GET) return respondText(request, .method_not_allowed, "405\n");
                return streamUpdates(io, request, conn_db, hub, arena);
            }
            if (std.mem.eql(u8, path, "/datastar.js")) {
                return respondAsset(request, datastar_js, "text/javascript; charset=utf-8");
            }
            if (std.mem.eql(u8, path, "/") or
                std.mem.eql(u8, path, "/users") or
                std.mem.eql(u8, path, "/index.html"))
            {
                return respondPage(request, arena.allocator(), conn_db);
            }
            return respondText(request, .not_found, "404 Not Found\n");
        },
        .POST => {
            if (std.mem.eql(u8, path, "/users/") or std.mem.eql(u8, path, "/users")) {
                return handleCreate(request, arena.allocator(), conn_db, hub);
            }
            return respondText(request, .not_found, "404 Not Found\n");
        },
        .DELETE => {
            if (std.mem.startsWith(u8, path, "/users/")) {
                return handleDelete(request, arena.allocator(), conn_db, hub, path["/users/".len..]);
            }
            return respondText(request, .not_found, "404 Not Found\n");
        },
        else => return respondText(request, .method_not_allowed, "405 Method Not Allowed\n"),
    }
}

// --- Read model ------------------------------------------------------------

fn respondPage(request: *std.http.Server.Request, arena: Allocator, conn_db: *sqlite.Db) !bool {
    const users = try db.allUsers(conn_db, arena);
    const body = try html.renderPageAlloc(arena, users);

    try request.respond(body, .{
        .status = .ok,
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
    return request.head.keep_alive;
}

/// GET /updates — the long-lived SSE read model. Pushes a fat morph of
/// `#content` on connect and on every subsequent data change, polling the hub
/// version between sleeps. Each event is rendered into the worker arena, which
/// is reset after the event is flushed.
fn streamUpdates(io: Io, request: *std.http.Server.Request, conn_db: *sqlite.Db, hub: *Hub, arena: *std.heap.ArenaAllocator) !bool {
    var stream_buffer: [stream_buffer_len]u8 = undefined;
    var body = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    });

    var seen: u64 = 0;
    var idle_polls: usize = 0;
    while (true) {
        const current = hub.current();
        if (current != seen) {
            seen = current;
            idle_polls = 0;
            const event = try renderContentEvent(arena.allocator(), conn_db);
            pushChunk(&body, event) catch return false;
            _ = arena.reset(.retain_capacity);
        } else {
            idle_polls += 1;
            if (idle_polls >= heartbeat_polls) {
                idle_polls = 0;
                // Comment line surfaces a dropped client as a write error.
                pushChunk(&body, ": keep-alive\n\n") catch return false;
            }
        }
        // Cancellation (shutdown) ends the stream.
        std.Io.sleep(io, poll_interval, .awake) catch return true;
    }
}

/// Write `bytes` to a chunked streaming body and flush all the way to the
/// socket. `BodyWriter.flush` only flushes the socket writer, so the body
/// buffer (which holds our just-written bytes) must be flushed first.
fn pushChunk(body: *std.http.BodyWriter, bytes: []const u8) !void {
    try body.writer.writeAll(bytes);
    try body.writer.flush(); // body buffer -> chunk framing -> socket buffer
    try body.flush(); // socket buffer -> client
}

/// Build one `datastar-patch-elements` SSE event carrying the current
/// `#content`, allocated in `arena` (along with its intermediates).
fn renderContentEvent(arena: Allocator, conn_db: *sqlite.Db) ![]const u8 {
    const users = try db.allUsers(conn_db, arena);
    const content = try html.renderContentAlloc(arena, users);
    return datastar.patchElements(arena, content, .{});
}

// --- Commands --------------------------------------------------------------

/// POST /users/ — validate the submitted Datastar signals and create a user.
/// On any problem, re-render the add dialog (targeted by id) with an error and
/// leave the entered values in place. On success, publish the change (the
/// stream re-renders the table), clear the form, and close the dialog.
fn handleCreate(request: *std.http.Server.Request, arena: Allocator, conn_db: *sqlite.Db, hub: *Hub) !bool {
    const signals = datastar.readSignals(CreateSignals, arena, request) catch {
        return dialogError(request, arena, "Could not read the submitted form.", null);
    };

    const name = std.mem.trim(u8, signals.name, " \t\r\n");
    const email = std.mem.trim(u8, signals.email, " \t\r\n");

    // Validate each field independently so every offending field shows its own
    // message directly beneath it.
    var name_err: ?[]const u8 = null;
    var email_err: ?[]const u8 = null;
    if (name.len == 0) name_err = "Name is required.";
    if (email.len == 0) {
        email_err = "Email is required.";
    } else if (!isValidEmail(email)) {
        email_err = "Please enter a valid email address.";
    }
    if (name_err != null or email_err != null) {
        return dialogError(request, arena, name_err, email_err);
    }

    _ = db.insertUser(conn_db, name, email, signals.role) catch |err| switch (err) {
        error.Constraint => return dialogError(request, arena, null, "That email is already in use."),
        else => return err,
    };

    hub.publish();

    // Success: the stream will refresh the table; here we just reset the form,
    // clear any field errors, and close the dialog (addOpen=false drives
    // data-effect to close the modal). The dialog element is never patched.
    return sendSse(request, arena, &.{
        try datastar.patchSignals(arena, .{
            .name = "",
            .email = "",
            .role = "member",
            .nameError = "",
            .emailError = "",
            .addOpen = false,
        }, .{}),
    });
}

/// DELETE /users/{id} — delete a user and publish. The table refresh arrives
/// over the stream; the confirmation dialog was already closed client-side.
fn handleDelete(request: *std.http.Server.Request, arena: Allocator, conn_db: *sqlite.Db, hub: *Hub, id_text: []const u8) !bool {
    const id = std.fmt.parseInt(i64, id_text, 10) catch {
        return respondText(request, .not_found, "404 Not Found\n");
    };

    try db.deleteUser(conn_db, id);
    hub.publish();

    return sendSse(request, arena, &.{});
}

/// Report per-field validation messages by patching the `$nameError` /
/// `$emailError` signals. The dialog element is untouched, so it stays open
/// (data-show/data-text surface the messages beneath their inputs). Both fields
/// are always sent so an empty string clears a stale message.
fn dialogError(request: *std.http.Server.Request, arena: Allocator, name_err: ?[]const u8, email_err: ?[]const u8) !bool {
    return sendSse(request, arena, &.{
        try datastar.patchSignals(arena, .{
            .nameError = name_err orelse "",
            .emailError = email_err orelse "",
        }, .{}),
    });
}

/// A basic email check, equivalent to the regex `^[^@\s]+@[^@\s]+\.[^@\s]+$`:
/// a non-empty local part, a single `@`, and a domain containing a dot that is
/// not at either end. Zig's standard library has no regex engine, so this is
/// spelled out directly.
fn isValidEmail(email: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0) return false; // empty local part
    if (std.mem.lastIndexOfScalar(u8, email, '@') != at) return false; // more than one '@'
    const domain = email[at + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return false;
    if (dot == 0 or dot == domain.len - 1) return false; // dot at start/end of domain
    for (email) |ch| if (ch <= ' ') return false; // no spaces or control characters
    return true;
}

// --- Response helpers ------------------------------------------------------

/// Send zero or more Datastar SSE events as a single (non-streaming) response.
fn sendSse(request: *std.http.Server.Request, arena: Allocator, events: []const []const u8) !bool {
    const body = try std.mem.concat(arena, u8, events);
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return false;
}

fn respondAsset(request: *std.http.Server.Request, body: []const u8, content_type: []const u8) !bool {
    try request.respond(body, .{
        .status = .ok,
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "max-age=3600" },
        },
    });
    return request.head.keep_alive;
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !bool {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    });
    return false;
}

// --- Tests -----------------------------------------------------------------

/// Drive `serve` over an in-memory request/response pair and return the raw
/// HTTP response bytes (caller owns them). Not usable for `/updates`, which
/// streams forever.
fn roundTrip(allocator: Allocator, conn_db: *sqlite.Db, hub: *Hub, raw_request: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var in = std.Io.Reader.fixed(raw_request);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var http_server = std.http.Server.init(&in, &out.writer);
    try serve(threaded.io(), &http_server, conn_db, hub, &arena);
    return out.toOwnedSlice();
}

fn testDb() !sqlite.Db {
    var d = try sqlite.Db.open(std.testing.allocator, ":memory:");
    errdefer d.close();
    try db.init(&d);
    return d;
}

fn userCount(d: *sqlite.Db) !usize {
    const users = try db.allUsers(d, std.testing.allocator);
    defer db.freeUsers(users, std.testing.allocator);
    return users.len;
}

test "isValidEmail accepts sane addresses and rejects junk" {
    try std.testing.expect(isValidEmail("a@b.co"));
    try std.testing.expect(isValidEmail("first.last@sub.example.com"));
    try std.testing.expect(!isValidEmail(""));
    try std.testing.expect(!isValidEmail("no-at-sign"));
    try std.testing.expect(!isValidEmail("@nolocal.com"));
    try std.testing.expect(!isValidEmail("noat.com"));
    try std.testing.expect(!isValidEmail("a@b"));
    try std.testing.expect(!isValidEmail("a@b."));
    try std.testing.expect(!isValidEmail("two@@x.com"));
    try std.testing.expect(!isValidEmail("has space@x.com"));
}

test "Hub.publish advances the version" {
    var hub: Hub = .{};
    try std.testing.expectEqual(@as(u64, 1), hub.current());
    hub.publish();
    try std.testing.expectEqual(@as(u64, 2), hub.current());
}

test "GET / boots the SSE stream and lists seeded users" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const response = try roundTrip(std.testing.allocator, &d, &hub, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "data-init=\"@get('/updates')\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Ada Lovelace") != null);
}

test "renderContentEvent emits a patch-elements event for #content" {
    var d = try testDb();
    defer d.close();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const event = try renderContentEvent(arena.allocator(), &d);

    try std.testing.expect(std.mem.indexOf(u8, event, "datastar-patch-elements") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "id=\"content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "Ada Lovelace") != null);
}

test "POST /users/ creates a user, publishes, and closes the dialog" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const body = "{\"name\":\"Barbara Liskov\",\"email\":\"barbara@example.com\",\"role\":\"member\"}";
    const request = std.fmt.comptimePrint(
        "POST /users/ HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const response = try roundTrip(std.testing.allocator, &d, &hub, request);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 6), try userCount(&d));
    try std.testing.expectEqual(@as(u64, 2), hub.current()); // published once
    // The command response resets the form and clears $addOpen to close the
    // dialog; it never carries the table.
    try std.testing.expect(std.mem.indexOf(u8, response, "datastar-patch-signals") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "addOpen") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Barbara Liskov") == null);
}

test "POST /users/ with an invalid email reports the error via signals" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const body = "{\"name\":\"Bad\",\"email\":\"not-an-email\",\"role\":\"member\"}";
    const request = std.fmt.comptimePrint(
        "POST /users/ HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const response = try roundTrip(std.testing.allocator, &d, &hub, request);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 5), try userCount(&d)); // nothing added
    try std.testing.expectEqual(@as(u64, 1), hub.current()); // not published
    try std.testing.expect(std.mem.indexOf(u8, response, "datastar-patch-signals") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "emailError") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "valid email") != null);
}

test "POST /users/ with an empty name is rejected" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const body = "{\"name\":\"  \",\"email\":\"x@y.com\",\"role\":\"member\"}";
    const request = std.fmt.comptimePrint(
        "POST /users/ HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const response = try roundTrip(std.testing.allocator, &d, &hub, request);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 5), try userCount(&d));
    try std.testing.expect(std.mem.indexOf(u8, response, "required") != null);
}

test "POST /users/ reports name and email errors independently" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    // Empty name AND invalid email: both field-error signals must be set with
    // their own message (the template places each beneath its own input).
    const body = "{\"name\":\"\",\"email\":\"nope\",\"role\":\"member\"}";
    const request = std.fmt.comptimePrint(
        "POST /users/ HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const response = try roundTrip(std.testing.allocator, &d, &hub, request);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"nameError\":\"Name is required.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"emailError\":\"Please enter a valid email address.\"") != null);
    try std.testing.expectEqual(@as(usize, 5), try userCount(&d));
}

test "POST /users/ with a duplicate email is rejected" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const body = "{\"name\":\"Impostor\",\"email\":\"ada@example.com\",\"role\":\"member\"}";
    const request = std.fmt.comptimePrint(
        "POST /users/ HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    const response = try roundTrip(std.testing.allocator, &d, &hub, request);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 5), try userCount(&d));
    try std.testing.expect(std.mem.indexOf(u8, response, "already in use") != null);
}

test "DELETE /users/{id} removes the user and publishes" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const response = try roundTrip(std.testing.allocator, &d, &hub, "DELETE /users/1 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}");
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 4), try userCount(&d));
    try std.testing.expectEqual(@as(u64, 2), hub.current());
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
}

test "unknown path returns 404" {
    var d = try testDb();
    defer d.close();
    var hub: Hub = .{};

    const response = try roundTrip(std.testing.allocator, &d, &hub, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 Not Found\r\n"));
}
