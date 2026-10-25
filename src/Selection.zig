// Mouse/agent text selection and the highlights made from it.
const std = @import("std");
const PdfHandler = @import("handlers/PdfHandler.zig");
const Positions = @import("services/Positions.zig");
const time = @import("utilities/time.zig");
const Context = @import("Context.zig").Context;
const PagePoint = @import("Context.zig").PagePoint;

// Drops the current selection-generation cache entry. Stale generations
// would otherwise squat in the LRU and evict prerendered neighbor pages.
fn dropSelectionEntry(ctx: *Context) void {
    const sp = ctx.selectionPage() orelse return;
    ctx.cache.remove(ctx.cacheKeyFor(sp)) catch {};
}

pub fn updateSelection(ctx: *Context, anchor: PagePoint, head: PagePoint) void {
    ctx.selection_hits.clearRetainingCapacity();
    if (ctx.selection_text.len > 0) {
        ctx.allocator.free(ctx.selection_text);
        ctx.selection_text = &.{};
    }
    ctx.selection_text = ctx.document_handler.selectText(
        ctx.allocator,
        anchor.page,
        anchor.x,
        anchor.y,
        head.x,
        head.y,
        &ctx.selection_hits,
    ) catch &.{};
    ctx.document_handler.setSelectionQuads(ctx.selection_hits.items);
    // Each re-render at high zoom is a multi-MB image transmit; during a
    // drag, refresh the visual at most a few times per second. The state
    // above is always current, so the release still copies exact text.
    const now = time.nowNs();
    if (now - ctx.selection_render_ns >= 250 * std.time.ns_per_ms) {
        ctx.selection_render_ns = now;
        dropSelectionEntry(ctx);
        ctx.selection_gen +%= 1;
    }
}

pub fn clearSelection(ctx: *Context) void {
    if (ctx.selection_hits.items.len == 0 and ctx.selection_text.len == 0) return;
    dropSelectionEntry(ctx);
    ctx.selection_hits.clearRetainingCapacity();
    if (ctx.selection_text.len > 0) {
        ctx.allocator.free(ctx.selection_text);
        ctx.selection_text = &.{};
    }
    ctx.document_handler.setSelectionQuads(&.{});
}

pub fn finishSelection(ctx: *Context) void {
    if (ctx.selection_text.len == 0) return;
    const w = ctx.tty.writer();
    ctx.vx.copyToSystemClipboard(w, ctx.selection_text, ctx.allocator) catch {};
    w.flush() catch {};
    // The throttle above may have skipped the last drag updates; render
    // the final selection state.
    dropSelectionEntry(ctx);
    ctx.selection_gen +%= 1;
    const msg = std.fmt.bufPrint(&ctx.progress_buf, " copied {d} chars ", .{ctx.selection_text.len}) catch return;
    ctx.setProgress(msg);
    publishSelection(ctx);
}

// For `re mcp` (current_page / reading_state show the selection).
fn publishSelection(ctx: *Context) void {
    if (ctx.allocator.dupe(u8, ctx.selection_text)) |copy| {
        if (ctx.presence.sel_text.len > 0) ctx.allocator.free(ctx.presence.sel_text);
        ctx.presence.sel_text = copy;
        ctx.presence.sel_page = if (ctx.selection_hits.items.len > 0) ctx.selection_hits.items[0].page else ctx.document_handler.getCurrentPageNumber();
        ctx.presence.sel_at = time.nowRealSeconds();
        ctx.publishPresence(ctx.presence.sel_at);
    } else |_| {}
}

// An agent's `select`: every occurrence of `text` on the page becomes the
// selection (shown inverted, `H` highlights it), the view scrolls there.
// Nothing goes to the clipboard.
pub fn selectTextOnPage(ctx: *Context, page: u16, text: []const u8) bool {
    const needle = ctx.allocator.dupeSentinel(u8, text, 0) catch return false;
    defer ctx.allocator.free(needle);
    var hits: std.ArrayList(PdfHandler.SearchHit) = .empty;
    defer hits.deinit(ctx.allocator);
    ctx.document_handler.searchPage(ctx.allocator, page, needle, &hits) catch return false;
    if (hits.items.len == 0) return false;
    clearSelection(ctx);
    ctx.selection_hits.appendSlice(ctx.allocator, hits.items) catch return false;
    ctx.selection_text = ctx.allocator.dupe(u8, text) catch &.{};
    ctx.selection_anchor = null;
    ctx.selection_dragged = false;
    ctx.document_handler.setSelectionQuads(ctx.selection_hits.items);
    dropSelectionEntry(ctx);
    ctx.selection_gen +%= 1;
    ctx.pushJump();
    ctx.gotoPagePdfY(page, hits.items[0].y0);
    publishSelection(ctx);
    return true;
}

pub fn rebuildHighlightQuads(ctx: *Context) void {
    applyHighlightQuads(ctx.allocator, &ctx.document_handler, ctx.highlights.items);
}

pub fn applyHighlightQuads(allocator: std.mem.Allocator, handler: *PdfHandler, highlights: []const Positions.Highlight) void {
    var flat: std.ArrayList(PdfHandler.SearchHit) = .empty;
    defer flat.deinit(allocator);
    for (highlights) |h| {
        var i: usize = 0;
        while (i + 3 < h.rects.len) : (i += 4) {
            flat.append(allocator, .{ .page = h.page, .x0 = h.rects[i], .y0 = h.rects[i + 1], .x1 = h.rects[i + 2], .y1 = h.rects[i + 3] }) catch break;
        }
    }
    handler.setHighlightQuads(flat.items);
}

pub fn freeHighlight(ctx: *Context, h: Positions.Highlight) void {
    if (h.text.len > 0) ctx.allocator.free(h.text);
    if (h.rects.len > 0) ctx.allocator.free(h.rects);
}

// Removal leaves a tombstone so other devices drop it on sync.
fn removeHighlight(ctx: *Context, idx: usize) void {
    const h = ctx.highlights.orderedRemove(idx);
    ctx.tombstones.append(ctx.allocator, .{ .kind = .highlight, .id = h.id, .deleted_at = time.nowRealSeconds() }) catch {};
    freeHighlight(ctx, h);
}

fn rectsOverlap(a: []const f32, b: []const f32) bool {
    var i: usize = 0;
    while (i + 3 < a.len) : (i += 4) {
        var j: usize = 0;
        while (j + 3 < b.len) : (j += 4) {
            if (a[i] < b[j + 2] and b[j] < a[i + 2] and a[i + 1] < b[j + 3] and b[j + 1] < a[i + 3]) return true;
        }
    }
    return false;
}

const HighlightData = struct { text: []const u8, rects: []f32 };

pub fn addHighlightFromSelection(ctx: *Context) void {
    if (ctx.selection_hits.items.len == 0) return;
    const page = ctx.selection_hits.items[0].page;

    var collected: std.ArrayList(f32) = .empty;
    defer collected.deinit(ctx.allocator);
    const merged_any = collectUnion(ctx, page, &collected) catch return;
    const data = (if (merged_any) reselectUnion(ctx, page, collected.items) else copyUnion(ctx, collected.items)) orelse return;
    commitHighlight(ctx, page, data, merged_any);
}

fn collectUnion(ctx: *Context, page: u16, collected: *std.ArrayList(f32)) !bool {
    for (ctx.selection_hits.items) |q| {
        try collected.appendSlice(ctx.allocator, &.{ q.x0, q.y0, q.x1, q.y1 });
    }

    // Absorb every existing highlight on this page that overlaps the
    // growing union (re-scanning so chains of overlaps merge too).
    var merged_any = false;
    var scan_again = true;
    while (scan_again) {
        scan_again = false;
        var i: usize = 0;
        while (i < ctx.highlights.items.len) : (i += 1) {
            const h = ctx.highlights.items[i];
            if (h.page != page or !rectsOverlap(h.rects, collected.items)) continue;
            try collected.appendSlice(ctx.allocator, h.rects);
            removeHighlight(ctx, i);
            merged_any = true;
            scan_again = true;
            break;
        }
    }
    return merged_any;
}

// Re-select from the union's first to last point in reading order:
// exact merged text plus clean per-line quads.
fn reselectUnion(ctx: *Context, page: u16, collected: []const f32) ?HighlightData {
    var first: [2]f32 = .{ collected[0], (collected[1] + collected[3]) / 2 };
    var last: [2]f32 = .{ collected[2], (collected[1] + collected[3]) / 2 };
    var i: usize = 4;
    while (i + 3 < collected.len) : (i += 4) {
        const cy = (collected[i + 1] + collected[i + 3]) / 2;
        if (cy < first[1] or (cy == first[1] and collected[i] < first[0])) first = .{ collected[i], cy };
        if (cy > last[1] or (cy == last[1] and collected[i + 2] > last[0])) last = .{ collected[i + 2], cy };
    }
    var merged_hits: std.ArrayList(PdfHandler.SearchHit) = .empty;
    defer merged_hits.deinit(ctx.allocator);
    const merged_text = ctx.document_handler.selectText(
        ctx.allocator,
        page,
        first[0] + 1,
        first[1],
        last[0] - 1,
        last[1],
        &merged_hits,
    ) catch &.{};
    if (merged_hits.items.len > 0) {
        const rects = ctx.allocator.alloc(f32, merged_hits.items.len * 4) catch return null;
        for (merged_hits.items, 0..) |q, qi| {
            rects[qi * 4] = q.x0;
            rects[qi * 4 + 1] = q.y0;
            rects[qi * 4 + 2] = q.x1;
            rects[qi * 4 + 3] = q.y1;
        }
        return .{ .text = merged_text, .rects = rects };
    }
    // Re-selection failed (e.g. non-text region): keep the raw union.
    if (merged_text.len > 0) ctx.allocator.free(merged_text);
    return copyUnion(ctx, collected);
}

fn copyUnion(ctx: *Context, collected: []const f32) ?HighlightData {
    const rects = ctx.allocator.dupe(f32, collected) catch return null;
    return .{ .text = ctx.allocator.dupe(u8, ctx.selection_text) catch "", .rects = rects };
}

fn commitHighlight(ctx: *Context, page: u16, data: HighlightData, merged_any: bool) void {
    ctx.highlights.append(ctx.allocator, .{
        .id = Positions.highlightId(page, data.rects),
        .page = page,
        .text = data.text,
        .rects = data.rects,
        .created_at = time.nowRealSeconds(),
    }) catch {
        ctx.allocator.free(data.rects);
        if (data.text.len > 0) ctx.allocator.free(@constCast(data.text));
        return;
    };
    clearSelection(ctx);
    rebuildHighlightQuads(ctx);
    ctx.clearCache();
    const msg = std.fmt.bufPrint(&ctx.progress_buf, " highlighted ({d} total{s}) ", .{
        ctx.highlights.items.len,
        if (merged_any) ", merged" else "",
    }) catch return;
    ctx.setProgress(msg);
}

pub fn deleteHighlight(ctx: *Context, idx: usize) void {
    if (idx >= ctx.highlights.items.len) return;
    removeHighlight(ctx, idx);
    rebuildHighlightQuads(ctx);
    ctx.clearCache();
}

pub fn jumpToHighlight(ctx: *Context, idx: usize) void {
    if (idx >= ctx.highlights.items.len) return;
    const h = ctx.highlights.items[idx];
    ctx.pushJump();
    ctx.gotoPagePdfY(h.page, if (h.rects.len >= 2) h.rects[1] else 0);
}

// Esc in view mode: drop the selection first; a second Esc clears search.
pub fn escapeClear(ctx: *Context) void {
    if (ctx.selection_hits.items.len > 0) {
        clearSelection(ctx);
        return;
    }
    ctx.clearSearch();
}
