// Status bar: placeholder expansion, drawing, and the displayed book path.
const std = @import("std");
const vaxis = @import("vaxis");
const Config = @import("config/Config.zig");
const Context = @import("Context.zig").Context;

pub fn drawStatusBar(ctx: *Context, win: vaxis.Window) !void {
    const arena = ctx.arena.allocator();

    const status_bar = win.child(.{
        .x_off = 0,
        .y_off = win.height -| 1,
        .width = win.width,
        .height = 1,
    });

    if (ctx.progress_text) |text| {
        status_bar.fill(vaxis.Cell{ .style = ctx.config.status_bar.style });
        _ = status_bar.print(&.{.{ .text = text, .style = ctx.config.status_bar.style }}, .{ .col_offset = 0 });
        return;
    }

    // Expand all items into styled sub-items
    var expanded_items: std.ArrayList(Config.StatusBar.StyledItem) = .empty;

    for (ctx.config.status_bar.items) |item| {
        const styled = switch (item) {
            .styled => |styled| styled,
            .mode_aware => |mode_aware| switch (ctx.current_mode) {
                .command => mode_aware.command,
                else => mode_aware.view,
            },
            .reload_aware => |reload_aware| switch (ctx.current_reload_indicator_state) {
                .idle => reload_aware.idle,
                .reload => reload_aware.reload,
                .watching => reload_aware.watching,
            },
        };
        try expandPlaceholders(arena, &expanded_items, styled);
    }

    const items = expanded_items.items;

    // Find the separator
    var separator_index: usize = items.len;
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item.text, Config.StatusBar.SEPARATOR)) {
            separator_index = i;
            break;
        }
    }

    if (separator_index < items.len) {
        status_bar.fill(vaxis.Cell{ .style = items[separator_index].style });
    } else {
        status_bar.fill(vaxis.Cell{ .style = ctx.config.status_bar.style });
    }

    // Left side
    var left_col: usize = 0;
    for (0..separator_index) |i| {
        try drawStatusText(ctx, status_bar, items[i], &left_col, true, arena);
    }

    // Right side
    if (items.len > 0 and separator_index < items.len - 1) {
        var right_col: usize = win.width;
        for (0..(items.len - separator_index - 1)) |j| {
            try drawStatusText(ctx, status_bar, items[items.len - 1 - j], &right_col, false, arena);
        }
    }
}

fn expandPlaceholders(arena: std.mem.Allocator, list: *std.ArrayList(Config.StatusBar.StyledItem), styled_text: Config.StatusBar.StyledItem) !void {
    const text = styled_text.text;
    var last_index: usize = 0;

    while (last_index < text.len) {
        const open = std.mem.indexOfScalarPos(u8, text, last_index, '<') orelse {
            if (last_index < text.len) {
                try list.append(arena, .{ .text = text[last_index..], .style = styled_text.style });
            }
            break;
        };

        if (open > last_index) {
            try list.append(arena, .{ .text = text[last_index..open], .style = styled_text.style });
        }

        const close = std.mem.indexOfScalarPos(u8, text, open, '>') orelse {
            try list.append(arena, .{ .text = text[open..], .style = styled_text.style });
            break;
        };

        try list.append(arena, .{ .text = text[open .. close + 1], .style = styled_text.style });

        last_index = close + 1;
    }
}

fn stripDirPrefix(path: []const u8, dir: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, dir)) return null;
    const rel = path[dir.len..];
    if (rel.len == 0) return rel;
    if (rel[0] != '/' and !std.mem.endsWith(u8, dir, "/")) return null;
    return std.mem.trimStart(u8, rel, "/");
}

// The status bar shows the book relative to cwd, else under ~/, else absolute.
pub fn displayPath(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, abs: []const u8) ![]u8 {
    if (std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator)) |cwd| {
        defer allocator.free(cwd);
        if (stripDirPrefix(abs, cwd)) |rel| return allocator.dupe(u8, rel);
    } else |_| {}
    if (env.get("HOME")) |home| if (stripDirPrefix(abs, home)) |rel| return std.fmt.allocPrint(allocator, "~/{s}", .{rel});
    return allocator.dupe(u8, abs);
}

// Title of the deepest outline entry at or before `page` ("current section").
fn chapterFor(ctx: *Context, page: u16) []const u8 {
    var title: []const u8 = "";
    for (ctx.outline) |e| {
        if (e.page > page) break;
        title = e.title;
    }
    return title;
}

fn drawStatusText(ctx: *Context, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
    var text = item.text;

    if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
        text = ctx.status_path;
    } else if (std.mem.eql(u8, text, Config.StatusBar.PAGE)) {
        text = try std.fmt.allocPrint(allocator, "{}", .{ctx.document_handler.getCurrentPageNumber() + 1});
    } else if (std.mem.eql(u8, text, Config.StatusBar.TOTAL_PAGES)) {
        text = try std.fmt.allocPrint(allocator, "{}", .{ctx.document_handler.getTotalPages()});
    } else if (std.mem.eql(u8, text, Config.StatusBar.SEPARATOR)) {
        text = "";
    } else if (std.mem.eql(u8, text, Config.StatusBar.HLOCK)) {
        text = if (ctx.lock_horizontal_scroll) " HLOCK " else "";
    } else if (std.mem.eql(u8, text, Config.StatusBar.FIT)) {
        text = if (ctx.document_handler.getFitWidth()) " FIT " else "";
    } else if (std.mem.eql(u8, text, Config.StatusBar.ODDX)) {
        const oddx = ctx.document_handler.getOddShiftX();
        text = if (oddx != 0)
            try std.fmt.allocPrint(allocator, " ODDX {d} ", .{oddx})
        else
            "";
    } else if (std.mem.eql(u8, text, Config.StatusBar.CROP)) {
        // CSS order (T R B L), matching what :crop accepts.
        text = if (ctx.document_handler.cropInfo()) |ci|
            try std.fmt.allocPrint(allocator, " CROP{s} {d:.0} {d:.0} {d:.0} {d:.0} ", .{
                if (ci.auto) "*" else "", ci.top, ci.right, ci.bottom, ci.left,
            })
        else
            "";
    } else if (std.mem.eql(u8, text, Config.StatusBar.CHAPTER)) {
        text = chapterFor(ctx, ctx.document_handler.getCurrentPageNumber());
    } else if (std.mem.eql(u8, text, Config.StatusBar.PERCENT)) {
        const total = ctx.document_handler.getTotalPages();
        const pct = if (total > 0) (@as(u32, ctx.document_handler.getCurrentPageNumber()) + 1) * 100 / total else 0;
        text = try std.fmt.allocPrint(allocator, "{d}", .{pct});
    } else if (std.mem.eql(u8, text, Config.StatusBar.SEARCH)) {
        text = if (ctx.search_hits.items.len > 0)
            try std.fmt.allocPrint(allocator, " {d}/{d} {s} ", .{ ctx.search_index + 1, ctx.search_hits.items.len, ctx.search_needle })
        else
            "";
    }

    const width = vaxis.gwidth.gwidth(text, .wcwidth);

    if (!left_aligned) {
        if (width > col_offset.*) return; // doesn't fit; skip the item
        col_offset.* -= width;
    }

    _ = status_bar.print(
        &.{.{ .text = text, .style = item.style }},
        .{ .col_offset = @intCast(col_offset.*) },
    );

    if (left_aligned) col_offset.* += width;
}

pub fn toggleFullScreen(ctx: *Context) void {
    ctx.config.status_bar.enabled = !ctx.config.status_bar.enabled;
}
