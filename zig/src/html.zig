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

test "add dialog is signal-driven with per-field error slots under each input" {
    const users = [_]db.User{
        .{ .id = 1, .name = "Ada", .email = "a@x.com", .role = "admin" },
    };
    const page = try renderPageAlloc(std.testing.allocator, &users);
    defer std.testing.allocator.free(page);

    // Open state is driven by the $addOpen signal via data-effect, not an attribute.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"add-dialog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-effect=") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<dialog id=\"add-dialog\" open") == null);

    // The name error slot sits between the name and email inputs; the email
    // error slot after the email input. Both are bound to their signals.
    const name_input = std.mem.indexOf(u8, page, "data-bind:name").?;
    const name_err = std.mem.indexOf(u8, page, "data-text=\"$nameError\"").?;
    const email_input = std.mem.indexOf(u8, page, "data-bind:email").?;
    const email_err = std.mem.indexOf(u8, page, "data-text=\"$emailError\"").?;
    try std.testing.expect(name_input < name_err);
    try std.testing.expect(name_err < email_input);
    try std.testing.expect(email_input < email_err);
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
