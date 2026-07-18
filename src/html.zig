//! Renders the users page and its morph-able fragments.
//!
//! The architecture is CQRS-flavored: the page shell opens a long-lived SSE
//! stream (via `data-init="@get('/updates')"`) that pushes "fat" morphs of the
//! `#content` region whenever the data changes. Commands (`POST`/`DELETE`) do
//! not return the table; they mutate and let the stream re-render it. The one
//! exception is the add-user dialog, which the create command re-renders (by
//! id) to show validation errors.
//!
//! All dynamic values are HTML-escaped so data from the database can never
//! break out of its element and inject markup.

const std = @import("std");
const db = @import("db.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// Write `text` to `w`, escaping the five characters that are significant in
/// HTML element/attribute text.
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

/// Render just the `<table id="users">` element.
pub fn renderTable(w: *Writer, users: []const db.User) Writer.Error!void {
    try w.print(
        \\<table id="users">
        \\      <caption>{d} user(s), live-updated over SSE</caption>
        \\      <thead>
        \\        <tr><th>ID</th><th>Name</th><th>Email</th><th>Role</th><th></th></tr>
        \\      </thead>
        \\      <tbody>
        \\
    , .{users.len});

    for (users) |u| {
        try w.print("        <tr><td>{d}</td><td>", .{u.id});
        try escape(w, u.name);
        try w.writeAll("</td><td>");
        try escape(w, u.email);
        try w.writeAll("</td><td class=\"role\">");
        try escape(w, u.role);
        try w.writeAll("</td><td>");
        try renderDeleteButton(w, u);
        try w.writeAll("</td></tr>\n");
    }

    try w.writeAll(
        \\      </tbody>
        \\    </table>
    );
}

/// The per-row Delete button. It stashes the row's id and name in `data-*`
/// attributes and, on click, copies them into signals and opens the shared
/// confirmation dialog — no server round-trip to *open* the dialog.
fn renderDeleteButton(w: *Writer, u: db.User) Writer.Error!void {
    try w.print("<button type=\"button\" class=\"danger\" data-user-id=\"{d}\" data-user-name=\"", .{u.id});
    try escape(w, u.name);
    try w.writeAll(
        \\" data-on:click="$deleteId = el.dataset.userId; $deleteName = el.dataset.userName; document.getElementById('confirm-dialog').showModal()">Delete</button>
    );
}

/// The `#content` region: the fat-morph target pushed by the `/updates` stream.
/// Re-rendering and morphing this whole region (rather than surgically patching
/// rows) is the "fat morph" approach.
pub fn renderContent(w: *Writer, users: []const db.User) Writer.Error!void {
    try w.writeAll("<main id=\"content\">\n    ");
    try renderTable(w, users);
    try w.writeAll("\n  </main>");
}

/// The add-user dialog. `open` controls whether it renders in the open state
/// (used when re-rendering after a validation error so the morph keeps it up),
/// and `err`, when present, is shown below the fields.
pub fn renderAddDialog(w: *Writer, open: bool, err: ?[]const u8) Writer.Error!void {
    try w.writeAll("<dialog id=\"add-dialog\"");
    if (open) try w.writeAll(" open");
    try w.writeAll(
        \\>
        \\    <form method="dialog">
        \\      <h2>Add user</h2>
        \\
    );
    if (err) |message| {
        try w.writeAll("      <p class=\"dialog-error\">");
        try escape(w, message);
        try w.writeAll("</p>\n");
    }
    try w.writeAll(
        \\      <label>Name<input data-bind:name placeholder="Jane Doe"></label>
        \\      <label>Email<input type="email" data-bind:email placeholder="jane@example.com"></label>
        \\      <label>Role
        \\        <select data-bind:role>
        \\          <option value="member">member</option>
        \\          <option value="admin">admin</option>
        \\        </select>
        \\      </label>
        \\      <menu>
        \\        <button value="cancel">Cancel</button>
        \\        <button type="button" class="primary" data-on:click="@post('/users/')">Save</button>
        \\      </menu>
        \\    </form>
        \\  </dialog>
    );
}

/// Render the full HTML document (the shell that boots the SSE stream).
pub fn renderPage(w: *Writer, users: []const db.User) Writer.Error!void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>Users</title>
        \\  <script type="module" src="/datastar.js"></script>
        \\  <style>
        \\    /* Colors are defined once with light-dark(): the browser picks the
        \\       light or dark value from the used `color-scheme`, which follows
        \\       the OS setting by default and can be overridden per-element. */
        \\    :root {
        \\      color-scheme: light dark;
        \\      --bg:            light-dark(#ffffff, #14181f);
        \\      --fg:            light-dark(#1a1a1a, #e7e9ee);
        \\      --muted:         light-dark(#666666, #9aa4b2);
        \\      --border:        light-dark(#dddddd, #2b3240);
        \\      --border-strong: light-dark(#999999, #3a4150);
        \\      --row-alt:       light-dark(#f6f6f6, #1b2029);
        \\      --btn-bg:        light-dark(#ffffff, #1b2029);
        \\      --btn-border:    light-dark(#bbbbbb, #3a4150);
        \\      --accent:        light-dark(#1a56db, #4f83ff);
        \\      --danger:        light-dark(#d1495b, #ff6b81);
        \\      --surface:       light-dark(#ffffff, #1b2029);
        \\      --shadow:        light-dark(rgba(0,0,0,.2), rgba(0,0,0,.6));
        \\      --backdrop:      light-dark(rgba(0,0,0,.35), rgba(0,0,0,.6));
        \\    }
        \\    /* The runtime listener (script at the end of <body>) sets
        \\       data-theme to force a specific scheme; without it, the OS wins. */
        \\    :root[data-theme="light"] { color-scheme: light; }
        \\    :root[data-theme="dark"]  { color-scheme: dark; }
        \\
        \\    body { font-family: system-ui, sans-serif; margin: 2rem; background: var(--bg); color: var(--fg); }
        \\    h1 { font-size: 1.5rem; }
        \\    table { border-collapse: collapse; width: 100%; max-width: 760px; }
        \\    caption { text-align: left; color: var(--muted); margin-bottom: .5rem; }
        \\    th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--border); }
        \\    thead th { border-bottom: 2px solid var(--border-strong); }
        \\    tbody tr:nth-child(even) { background: var(--row-alt); }
        \\    .role { font-size: .8rem; text-transform: uppercase; letter-spacing: .03em; color: var(--muted); }
        \\    button { font: inherit; padding: .35rem .7rem; border-radius: 6px; border: 1px solid var(--btn-border); background: var(--btn-bg); color: var(--fg); cursor: pointer; }
        \\    button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        \\    button.danger { border-color: var(--danger); color: var(--danger); }
        \\    .toolbar { margin: 1rem 0; display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
        \\    .theme-tag { color: var(--muted); font-size: .85rem; }
        \\    dialog { border: none; border-radius: 10px; padding: 1.25rem 1.5rem; background: var(--surface); color: var(--fg); box-shadow: 0 10px 40px var(--shadow); }
        \\    dialog::backdrop { background: var(--backdrop); }
        \\    dialog h2 { margin-top: 0; }
        \\    dialog label { display: block; margin: .6rem 0; }
        \\    dialog input, dialog select { font: inherit; padding: .3rem; width: 100%; box-sizing: border-box; }
        \\    dialog menu { display: flex; gap: .5rem; justify-content: flex-end; padding: 0; margin: 1rem 0 0; }
        \\    .dialog-error { color: var(--danger); font-weight: 600; margin: .25rem 0 .5rem; }
        \\  </style>
        \\</head>
        \\<body data-signals="{name: '', email: '', role: 'member', deleteId: '', deleteName: ''}" data-init="@get('/updates')">
        \\  <h1>Users</h1>
        \\  <div class="toolbar">
        \\    <button class="primary" data-on:click="document.getElementById('add-dialog').showModal()">Add user</button>
        \\    <span class="theme-tag">Theme: <b id="theme-name">…</b> (follows your system)</span>
        \\  </div>
        \\
    );
    try renderContent(w, users);
    try w.writeAll("\n\n  ");
    try renderAddDialog(w, false, null);
    try w.writeAll(
        \\
        \\
        \\  <dialog id="confirm-dialog">
        \\    <form method="dialog">
        \\      <h2>Delete user</h2>
        \\      <p>Really delete <strong data-text="$deleteName"></strong>?</p>
        \\      <menu>
        \\        <button value="cancel">Cancel</button>
        \\        <button type="button" class="danger" data-on:click="@delete('/users/' + $deleteId); document.getElementById('confirm-dialog').close()">Delete</button>
        \\      </menu>
        \\    </form>
        \\  </dialog>
        \\
        \\  <script>
        \\    // Track the OS light/dark preference and react to changes at runtime.
        \\    // The CSS already re-themes on its own via `color-scheme` + light-dark();
        \\    // this listener mirrors the current mode into `data-theme` (so it can be
        \\    // overridden), updates the on-page indicator, and emits a `themechange`
        \\    // event as a hook for any other runtime reaction.
        \\    (function () {
        \\      const query = window.matchMedia("(prefers-color-scheme: dark)");
        \\      function applyTheme() {
        \\        const mode = query.matches ? "dark" : "light";
        \\        document.documentElement.dataset.theme = mode;
        \\        const label = document.getElementById("theme-name");
        \\        if (label) label.textContent = mode;
        \\        document.dispatchEvent(new CustomEvent("themechange", { detail: { mode } }));
        \\      }
        \\      query.addEventListener("change", applyTheme);
        \\      applyTheme();
        \\    })();
        \\  </script>
        \\</body>
        \\</html>
        \\
    );
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
pub fn renderAddDialogAlloc(allocator: Allocator, open: bool, err: ?[]const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    renderAddDialog(&aw.writer, open, err) catch |e| switch (e) {
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

test "renderAddDialog shows the error and open state only when asked" {
    const clean = try renderAddDialogAlloc(std.testing.allocator, false, null);
    defer std.testing.allocator.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "dialog-error") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "<dialog id=\"add-dialog\">") != null);

    const errored = try renderAddDialogAlloc(std.testing.allocator, true, "Bad email");
    defer std.testing.allocator.free(errored);
    try std.testing.expect(std.mem.indexOf(u8, errored, "<dialog id=\"add-dialog\" open>") != null);
    try std.testing.expect(std.mem.indexOf(u8, errored, "Bad email") != null);
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
