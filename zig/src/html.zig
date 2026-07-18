//! Adapter over the generated `templates/users.zig` (transpiled from
//! `templates/users.zt`; see build.zig). Exposes the `render*`/`render*Alloc`
//! API the server calls. zt escapes every `{expr}`, so database values cannot
//! inject markup. Request flow: see the `server` module header.

const std = @import("std");
const db = @import("db.zig");
const templates = @import("templates/users.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// Escape the five markup-significant characters. For values built outside a
/// template; zt escapes `{expr}` internally.
pub fn escape(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(ch),
        }
    }
}

/// The `#content` region: the fat-morph target pushed by the `/updates` stream.
pub fn renderContent(w: *Writer, users: []const db.User) Writer.Error!void {
    try templates.Content.render(.{users}, w);
}

/// The add-user dialog. `open` renders it in the open state (used when
/// re-rendering after a validation error so the morph keeps it up). Each field
/// error, when present, is shown directly beneath that field's input.
pub fn renderAddDialog(w: *Writer, open: bool, name_err: ?[]const u8, email_err: ?[]const u8) Writer.Error!void {
    try templates.AddDialog.render(.{ open, name_err, email_err }, w);
}

/// Render the full HTML document (the shell that boots the SSE stream).
pub fn renderPage(w: *Writer, users: []const db.User) Writer.Error!void {
    try templates.Page.render(.{users}, w);
}

/// Render the users page into a freshly allocated buffer owned by the caller.
pub fn renderPageAlloc(allocator: Allocator, users: []const db.User) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    renderPage(&aw.writer, users) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

/// Render the `#content` region into a freshly allocated buffer.
pub fn renderContentAlloc(allocator: Allocator, users: []const db.User) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    renderContent(&aw.writer, users) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

/// Render the add-user dialog into a freshly allocated buffer.
pub fn renderAddDialogAlloc(allocator: Allocator, open: bool, name_err: ?[]const u8, email_err: ?[]const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    renderAddDialog(&aw.writer, open, name_err, email_err) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

test "escape encodes markup-significant characters" {
    var buf: [128]u8 = undefined;
    var w = Writer.fixed(&buf);
    try escape(&w, "a<b>&\"'");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#39;", w.buffered());
}

test "renderContent wraps the escaped table with the morph target id" {
    const users = [_]db.User{
        .{ .id = 1, .name = "Ada <script>", .email = "a@x.com", .role = "admin" },
    };
    const content = try renderContentAlloc(std.testing.allocator, &users);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, "<main id=\"content\">"));
    try std.testing.expect(std.mem.indexOf(u8, content, "<table id=\"users\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Ada &lt;script&gt;") != null);
}

test "renderAddDialog shows per-field errors and open state only when asked" {
    const clean = try renderAddDialogAlloc(std.testing.allocator, false, null, null);
    defer std.testing.allocator.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "field-error") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "<dialog id=\"add-dialog\">") != null);

    // A name error appears before the email input; an email error after it.
    const errored = try renderAddDialogAlloc(std.testing.allocator, true, "Name required", "Bad email");
    defer std.testing.allocator.free(errored);
    try std.testing.expect(std.mem.indexOf(u8, errored, "<dialog id=\"add-dialog\" open>") != null);
    const name_pos = std.mem.indexOf(u8, errored, "Name required").?;
    const email_input_pos = std.mem.indexOf(u8, errored, "data-bind:email").?;
    const email_err_pos = std.mem.indexOf(u8, errored, "Bad email").?;
    try std.testing.expect(name_pos < email_input_pos);
    try std.testing.expect(email_input_pos < email_err_pos);
}

test "renderPage boots the SSE stream and includes theming + datastar" {
    const users = [_]db.User{
        .{ .id = 1, .name = "Ada", .email = "a@x.com", .role = "admin" },
    };
    const page = try renderPageAlloc(std.testing.allocator, &users);
    defer std.testing.allocator.free(page);

    try std.testing.expect(std.mem.indexOf(u8, page, "/datastar.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-init=\"@get('/updates')\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<main id=\"content\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"add-dialog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "@post('/users/')") != null);
    // Datastar colon syntax and light/dark theming must be present.
    try std.testing.expect(std.mem.indexOf(u8, page, "data-on:click=") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-on-click") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "color-scheme: light dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "light-dark(") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "addEventListener(\"change\"") != null);
}
