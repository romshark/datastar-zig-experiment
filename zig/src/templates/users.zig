// Auto-generated from users.zt - do not edit
const std = @import("std");
const zt = @import("zt");

// Users page and its morph-able fragments, as zt templates.
//
// Source of truth: build.zig `addTemplates` transpiles this to the generated
// `users.zig`. Edit this file. zt escapes every `{expr}`, so database values
// cannot inject markup. Request flow: see the `server` module header.

const db = @import("../db.zig");

// Initial Datastar signals. The literal's `{ }` would parse as an interpolation
// in an attribute, so it is wrapped in `formatHtml` (which zt treats as
// pre-escaped HTML) and emitted verbatim.
const Raw = struct {
    s: []const u8,
    pub fn formatHtml(self: Raw, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.s);
    }
};
const SIGNALS = Raw{ .s = "{name: '', email: '', role: 'member', deleteId: '', deleteName: '', addOpen: false, nameError: '', emailError: ''}" };

// The per-row Delete button. It stashes the row's id and name in `data-*`
// attributes and, on click, copies them into signals and opens the shared
// confirmation dialog — no server round-trip to *open* the dialog.

// Just the `<table id="users">` element.

// The `#content` region: the fat-morph target pushed by the `/updates` stream.

// Shared inner form for the add-user dialog. Field errors are driven by the
// `$nameError` / `$emailError` signals (data-text fills the message, data-show
// hides the paragraph while empty), so the server reports validation failures by
// patching signals rather than re-rendering the dialog.

// The add-user dialog. Its open state is driven by the `$addOpen` signal:
// data-effect opens the modal when the signal is set and closes it when cleared
// (`el.open` guards against calling showModal on an already-open dialog, which
// throws). data-on:close keeps the signal in sync when the user dismisses the
// dialog with Escape or Cancel, and clears any field errors. The dialog is never
// re-rendered by the server, so its open state is not disturbed; errors arrive
// as signal patches (see AddForm).

// The full HTML document (the shell that boots the SSE stream). The <style> and
// <script> blocks are raw-text elements in zt, so their literal `{ }` are left
// untouched.

const DeleteButton = struct {
    fn _render(u: db.User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &u;
        // users.zt:24
        try writer.writeAll("<button");
        try writer.writeAll(" type=\"button\"");
        try writer.writeAll(" class=\"danger\"");
        try zt.writeAttr(writer, "data-user-id", u.id);
        try zt.writeAttr(writer, "data-user-name", u.name);
        try writer.writeAll(" data-on:click=\"$deleteId = el.dataset.userId; $deleteName = el.dataset.userName; document.getElementById('confirm-dialog').showModal()\"");
        try writer.writeAll(">");
        try writer.writeAll("Delete");
        // users.zt:25
        try writer.writeAll("</button>");
    }

    fn _signature(_: db.User) void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

const Table = struct {
    fn _render(users: []const db.User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &users;
        // users.zt:30
        try writer.writeAll("<table id=\"users\">");
        // users.zt:31
        try writer.writeAll("<caption>");
        try zt.writeEscaped(writer, users.len);
        try writer.writeAll(" user(s), live-updated over SSE");
        try writer.writeAll("</caption>");
        // users.zt:32
        try writer.writeAll("<thead>");
        // users.zt:33
        try writer.writeAll("<tr>");
        try writer.writeAll("<th>");
        try writer.writeAll("ID");
        try writer.writeAll("</th>");
        try writer.writeAll("<th>");
        try writer.writeAll("Name");
        try writer.writeAll("</th>");
        try writer.writeAll("<th>");
        try writer.writeAll("Email");
        try writer.writeAll("</th>");
        try writer.writeAll("<th>");
        try writer.writeAll("Role");
        try writer.writeAll("</th>");
        try writer.writeAll("<th>");
        try writer.writeAll("</th>");
        try writer.writeAll("</tr>");
        // users.zt:34
        try writer.writeAll("</thead>");
        // users.zt:35
        try writer.writeAll("<tbody>");
        // users.zt:36
        for (users) |u| {
            // users.zt:37
            try writer.writeAll("<tr>");
            // users.zt:38
            try writer.writeAll("<td>");
            try zt.writeEscaped(writer, u.id);
            try writer.writeAll("</td>");
            // users.zt:39
            try writer.writeAll("<td>");
            try zt.writeEscaped(writer, u.name);
            try writer.writeAll("</td>");
            // users.zt:40
            try writer.writeAll("<td>");
            try zt.writeEscaped(writer, u.email);
            try writer.writeAll("</td>");
            // users.zt:41
            try writer.writeAll("<td class=\"role\">");
            try zt.writeEscaped(writer, u.role);
            try writer.writeAll("</td>");
            // users.zt:42
            try writer.writeAll("<td>");
            // users.zt:43
            try zt.renderComponent(DeleteButton, .{u}, writer);
            // users.zt:44
            try writer.writeAll("</td>");
            // users.zt:45
            try writer.writeAll("</tr>");
        }
        // users.zt:47
        try writer.writeAll("</tbody>");
        // users.zt:48
        try writer.writeAll("</table>");
    }

    fn _signature(_: []const db.User) void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

pub const Content = struct {
    fn _render(users: []const db.User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &users;
        // users.zt:53
        try writer.writeAll("<main id=\"content\">");
        // users.zt:54
        try zt.renderComponent(Table, .{users}, writer);
        // users.zt:55
        try writer.writeAll("</main>");
    }

    fn _signature(_: []const db.User) void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

const AddForm = struct {
    fn _render(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // users.zt:63
        try writer.writeAll("<form method=\"dialog\">");
        // users.zt:64
        try writer.writeAll("<h2>");
        try writer.writeAll("Add user");
        try writer.writeAll("</h2>");
        // users.zt:65
        try writer.writeAll("<label>");
        try writer.writeAll("Name");
        try writer.writeAll("<input data-bind:name placeholder=\"Jane Doe\">");
        try writer.writeAll("</label>");
        // users.zt:66
        try writer.writeAll("<p class=\"field-error\" data-show=\"$nameError\" data-text=\"$nameError\">");
        try writer.writeAll("</p>");
        // users.zt:67
        try writer.writeAll("<label>");
        try writer.writeAll("Email");
        try writer.writeAll("<input type=\"email\" data-bind:email placeholder=\"jane@example.com\">");
        try writer.writeAll("</label>");
        // users.zt:68
        try writer.writeAll("<p class=\"field-error\" data-show=\"$emailError\" data-text=\"$emailError\">");
        try writer.writeAll("</p>");
        // users.zt:69
        try writer.writeAll("<label>");
        try writer.writeAll("Role\n            ");
        // users.zt:70
        try writer.writeAll("<select data-bind:role>");
        // users.zt:71
        try writer.writeAll("<option value=\"member\">");
        try writer.writeAll("member");
        try writer.writeAll("</option>");
        // users.zt:72
        try writer.writeAll("<option value=\"admin\">");
        try writer.writeAll("admin");
        try writer.writeAll("</option>");
        // users.zt:73
        try writer.writeAll("</select>");
        // users.zt:74
        try writer.writeAll("</label>");
        // users.zt:75
        try writer.writeAll("<menu>");
        // users.zt:76
        try writer.writeAll("<button value=\"cancel\">");
        try writer.writeAll("Cancel");
        try writer.writeAll("</button>");
        // users.zt:77
        try writer.writeAll("<button type=\"button\" class=\"primary\" data-on:click=\"@post('/users/')\">");
        try writer.writeAll("Save");
        try writer.writeAll("</button>");
        // users.zt:78
        try writer.writeAll("</menu>");
        // users.zt:79
        try writer.writeAll("</form>");
    }

    fn _signature() void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

pub const AddDialog = struct {
    fn _render(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // users.zt:90
        try writer.writeAll("<dialog id=\"add-dialog\" data-effect=\"$addOpen ? (el.open || el.showModal()) : el.close()\" data-on:close=\"$addOpen = false; $nameError = ''; $emailError = ''\">");
        // users.zt:91
        try zt.renderComponent(AddForm, .{}, writer);
        // users.zt:92
        try writer.writeAll("</dialog>");
    }

    fn _signature() void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

pub const Page = struct {
    fn _render(users: []const db.User, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = &users;
        try writer.writeAll("<!DOCTYPE html>");
        // users.zt:100
        try writer.writeAll("<html lang=\"en\">");
        // users.zt:101
        try writer.writeAll("<head>");
        // users.zt:102
        try writer.writeAll("<meta charset=\"utf-8\">");
        // users.zt:103
        try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        // users.zt:104
        try writer.writeAll("<title>");
        try writer.writeAll("Users");
        try writer.writeAll("</title>");
        // users.zt:105
        try writer.writeAll("<script type=\"module\" src=\"/datastar.js\">");
        try writer.writeAll("</script>");
        // users.zt:106
        try writer.writeAll("<style>");
        try writer.writeAll("\n    /* Colors are defined once with light-dark(): the browser picks the\n       light or dark value from the used `color-scheme`, which follows\n       the OS setting by default and can be overridden per-element. */\n    :root {\n      color-scheme: light dark;\n      --bg:            light-dark(#ffffff, #14181f);\n      --fg:            light-dark(#1a1a1a, #e7e9ee);\n      --muted:         light-dark(#666666, #9aa4b2);\n      --border:        light-dark(#dddddd, #2b3240);\n      --border-strong: light-dark(#999999, #3a4150);\n      --row-alt:       light-dark(#f6f6f6, #1b2029);\n      --btn-bg:        light-dark(#ffffff, #1b2029);\n      --btn-border:    light-dark(#bbbbbb, #3a4150);\n      --accent:        light-dark(#1a56db, #4f83ff);\n      --danger:        light-dark(#d1495b, #ff6b81);\n      --surface:       light-dark(#ffffff, #1b2029);\n      --shadow:        light-dark(rgba(0,0,0,.2), rgba(0,0,0,.6));\n      --backdrop:      light-dark(rgba(0,0,0,.35), rgba(0,0,0,.6));\n    }\n    /* The runtime listener (script at the end of <body>) sets\n       data-theme to force a specific scheme; without it, the OS wins. */\n    :root[data-theme=\"light\"] { color-scheme: light; }\n    :root[data-theme=\"dark\"]  { color-scheme: dark; }\n\n    body { font-family: system-ui, sans-serif; margin: 2rem; background: var(--bg); color: var(--fg); }\n    h1 { font-size: 1.5rem; }\n    table { border-collapse: collapse; width: 100%; max-width: 760px; }\n    caption { text-align: left; color: var(--muted); margin-bottom: .5rem; }\n    th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--border); }\n    thead th { border-bottom: 2px solid var(--border-strong); }\n    tbody tr:nth-child(even) { background: var(--row-alt); }\n    .role { font-size: .8rem; text-transform: uppercase; letter-spacing: .03em; color: var(--muted); }\n    button { font: inherit; padding: .35rem .7rem; border-radius: 6px; border: 1px solid var(--btn-border); background: var(--btn-bg); color: var(--fg); cursor: pointer; }\n    button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }\n    button.danger { border-color: var(--danger); color: var(--danger); }\n    .toolbar { margin: 1rem 0; display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }\n    .theme-tag { color: var(--muted); font-size: .85rem; }\n    dialog { border: none; border-radius: 10px; padding: 1.25rem 1.5rem; background: var(--surface); color: var(--fg); box-shadow: 0 10px 40px var(--shadow); }\n    dialog::backdrop { background: var(--backdrop); }\n    dialog h2 { margin-top: 0; }\n    dialog label { display: block; margin: .6rem 0; }\n    dialog input, dialog select { font: inherit; padding: .3rem; width: 100%; box-sizing: border-box; }\n    dialog menu { display: flex; gap: .5rem; justify-content: flex-end; padding: 0; margin: 1rem 0 0; }\n    .field-error { color: var(--danger); font-weight: 600; font-size: .85rem; margin: -.35rem 0 .4rem; }\n        ");
        // users.zt:151
        try writer.writeAll("</style>");
        // users.zt:152
        try writer.writeAll("</head>");
        // users.zt:153
        try writer.writeAll("<body");
        try zt.writeAttr(writer, "data-signals", SIGNALS);
        try writer.writeAll(" data-init=\"@get('/updates')\"");
        try writer.writeAll(">");
        // users.zt:154
        try writer.writeAll("<h1>");
        try writer.writeAll("Users");
        try writer.writeAll("</h1>");
        // users.zt:155
        try writer.writeAll("<div class=\"toolbar\">");
        // users.zt:156
        try writer.writeAll("<button class=\"primary\" data-on:click=\"$addOpen = true\">");
        try writer.writeAll("Add user");
        try writer.writeAll("</button>");
        // users.zt:157
        try writer.writeAll("<span class=\"theme-tag\">");
        try writer.writeAll("Theme: ");
        try writer.writeAll("<b id=\"theme-name\">");
        try writer.writeAll("…");
        try writer.writeAll("</b>");
        try writer.writeAll(" (follows your system)");
        try writer.writeAll("</span>");
        // users.zt:158
        try writer.writeAll("</div>");
        // users.zt:159
        try zt.renderComponent(Content, .{users}, writer);
        // users.zt:160
        try zt.renderComponent(AddDialog, .{}, writer);
        // users.zt:161
        try writer.writeAll("<dialog id=\"confirm-dialog\">");
        // users.zt:162
        try writer.writeAll("<form method=\"dialog\">");
        // users.zt:163
        try writer.writeAll("<h2>");
        try writer.writeAll("Delete user");
        try writer.writeAll("</h2>");
        // users.zt:164
        try writer.writeAll("<p>");
        try writer.writeAll("Really delete ");
        try writer.writeAll("<strong data-text=\"$deleteName\">");
        try writer.writeAll("</strong>");
        try writer.writeAll("?");
        try writer.writeAll("</p>");
        // users.zt:165
        try writer.writeAll("<menu>");
        // users.zt:166
        try writer.writeAll("<button value=\"cancel\">");
        try writer.writeAll("Cancel");
        try writer.writeAll("</button>");
        // users.zt:167
        try writer.writeAll("<button type=\"button\" class=\"danger\" data-on:click=\"@delete('/users/' + $deleteId); document.getElementById('confirm-dialog').close()\">");
        try writer.writeAll("Delete");
        try writer.writeAll("</button>");
        // users.zt:168
        try writer.writeAll("</menu>");
        // users.zt:169
        try writer.writeAll("</form>");
        // users.zt:170
        try writer.writeAll("</dialog>");
        // users.zt:171
        try writer.writeAll("<script>");
        try writer.writeAll("\n    // CSS already re-themes via `color-scheme` + light-dark(). This listener\n    // adds runtime reaction: it mirrors the current mode into `data-theme` (an\n    // override hook), updates the indicator, and emits a `themechange` event.\n    (function () {\n      const query = window.matchMedia(\"(prefers-color-scheme: dark)\");\n      function applyTheme() {\n        const mode = query.matches ? \"dark\" : \"light\";\n        document.documentElement.dataset.theme = mode;\n        const label = document.getElementById(\"theme-name\");\n        if (label) label.textContent = mode;\n        document.dispatchEvent(new CustomEvent(\"themechange\", { detail: { mode } }));\n      }\n      query.addEventListener(\"change\", applyTheme);\n      applyTheme();\n    })();\n        ");
        // users.zt:187
        try writer.writeAll("</script>");
        // users.zt:188
        try writer.writeAll("</body>");
        // users.zt:189
        try writer.writeAll("</html>");
    }

    fn _signature(_: []const db.User) void {}

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);
                }
            }.f,
        };
    }
};

