const std = @import("std");
const vaxis = @import("vaxis");
const ViewMode = @import("modes/ViewMode.zig");
const CommandMode = @import("modes/CommandMode.zig");
const HintMode = @import("modes/HintMode.zig");
const MarksMode = @import("modes/MarksMode.zig");
const TocMode = @import("modes/TocMode.zig");
const HelpMode = @import("modes/HelpMode.zig");
const SearchMode = @import("modes/SearchMode.zig");
const SearchListMode = @import("modes/SearchListMode.zig");
const HighlightsMode = @import("modes/HighlightsMode.zig");
const CropMode = @import("modes/CropMode.zig");
const GridMode = @import("modes/GridMode.zig");
const fzwatch = @import("fzwatch");
const Config = @import("config/Config.zig");
const PdfHandler = @import("handlers/PdfHandler.zig");
const Cache = @import("./Cache.zig");
const ReloadIndicatorTimer = @import("services/ReloadIndicatorTimer.zig");
const History = @import("services/History.zig");
const Positions = @import("services/Positions.zig");
const Prerenderer = @import("services/Prerenderer.zig");
const time = @import("utilities/time.zig");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    file_changed,
    reload_done: usize,
    prerender_ready,
};

pub const ModeType = enum { view, command, hint, marks, toc, help, search, search_list, highlights, crop, grid };
pub const Mode = union(ModeType) { view: ViewMode, command: CommandMode, hint: HintMode, marks: MarksMode, toc: TocMode, help: HelpMode, search: SearchMode, search_list: SearchListMode, highlights: HighlightsMode, crop: CropMode, grid: GridMode };
pub const ReloadIndicatorState = enum { idle, reload, watching };

pub const VisiblePage = struct {
    page_num: u16,
    vp_y_top: u32,
    vp_y_bot: u32,
    vp_x_left: u32,
    vp_x_right: u32,
    clip_x: u32,
    clip_y: u32,
    origin_x: f32,
    origin_y: f32,

    // Viewport pixel position of a rendered-space pdf coordinate; the inverse
    // of pdfPointAt's mapping. May fall outside this segment.
    pub fn vpX(p: VisiblePage, pdf_x: f32, zoom: f32) f32 {
        return @as(f32, @floatFromInt(p.vp_x_left)) + (pdf_x - p.origin_x) * zoom - @as(f32, @floatFromInt(p.clip_x));
    }
    pub fn vpY(p: VisiblePage, pdf_y: f32, zoom: f32) f32 {
        return @as(f32, @floatFromInt(p.vp_y_top)) + (pdf_y - p.origin_y) * zoom - @as(f32, @floatFromInt(p.clip_y));
    }
};

pub const JumpPosition = struct {
    page: u16,
    scroll_y: i32,
    scroll_x: i32,
};

pub const PagePoint = struct {
    page: u16,
    x: f32,
    y: f32,
};

const max_jumps: usize = 100;

pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    document_handler: PdfHandler,
    page_info_text: []u8,
    current_page: ?vaxis.Image,
    watcher: ?fzwatch.Watcher,
    watcher_thread: ?std.Thread,
    config: *Config,
    loop: ?*vaxis.Loop(Event),
    current_mode: Mode,
    history: History,
    positions: Positions,
    doc_key: []u8,
    doc_abs_path: [:0]u8,
    outline: []const PdfHandler.OutlineEntry,
    reload_page: bool,
    cache: Cache,
    reload_indicator_timer: ReloadIndicatorTimer,
    current_reload_indicator_state: ReloadIndicatorState,
    reload_indicator_active: bool,
    buf: []u8,
    visible_pages: [8]VisiblePage,
    visible_pages_len: usize,
    last_pix_per_col: u16,
    last_pix_per_row: u16,
    // Visible page area in device pixels, captured each draw; drives half-page scroll.
    last_viewport_h_pix: u32,
    jump_back: std.ArrayList(JumpPosition),
    jump_forward: std.ArrayList(JumpPosition),
    lock_horizontal_scroll: bool,
    marks: std.ArrayList(Positions.Mark),
    highlights: std.ArrayList(Positions.Highlight),
    pending_op: ?enum { set_mark, jump_mark },
    progress_text: ?[]const u8,
    progress_buf: [128]u8,
    search_hits: std.ArrayList(PdfHandler.SearchHit),
    search_needle: []u8,
    search_index: usize,
    prerenderer: Prerenderer,
    selection_anchor: ?PagePoint,
    selection_dragged: bool,
    selection_hits: std.ArrayList(PdfHandler.SearchHit),
    selection_text: []u8,
    selection_gen: u32,
    selection_render_ns: i64,
    // Images displaced from the cache; deleted terminal-side after the next
    // render (deleting before would blank their placements for a frame).
    stale_images: std.ArrayList(Cache.CachedImage),
    last_save_sig: u64,
    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, path: [:0]const u8, initial_page: ?u16) !Self {
        const config = try allocator.create(Config);
        errdefer allocator.destroy(config);
        config.* = Config.init(allocator, io, env);
        errdefer config.deinit();

        var document_handler = try PdfHandler.init(allocator, io, path, initial_page, config);
        errdefer document_handler.deinit();

        const doc_key = try document_handler.getDocumentKey(allocator);
        errdefer allocator.free(doc_key);

        const doc_abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch try allocator.dupeZ(u8, path);
        errdefer allocator.free(doc_abs_path);

        var positions = Positions.init(allocator, io, env, config, doc_key);
        errdefer positions.deinit();
        // An explicit page argument overrides only the position; view settings
        // (zoom/crop/spread/...) are always restored, otherwise the next
        // auto-save would overwrite them with defaults.
        if (positions.getSavedPositionForKey(document_handler.getPath())) |pos| {
            config.general.colorize = pos.colorize;
            // Crop/spread first: their toggles reset zoom/scroll, so they must
            // run before we restore them or they wipe the restored values.
            if (pos.crop != document_handler.getCropToContent()) {
                document_handler.toggleCropToContent();
            }
            if (pos.spread != document_handler.getSpread()) {
                document_handler.toggleSpread();
            }
            if (pos.crop_left != 0 or pos.crop_right != 0 or pos.crop_top != 0 or pos.crop_bottom != 0) {
                document_handler.setMarginCrop(pos.crop_left, pos.crop_right, pos.crop_top, pos.crop_bottom);
            }
            if (initial_page == null and pos.page < document_handler.getTotalPages()) {
                document_handler.setCurrentPage(pos.page);
                document_handler.setScrollX(pos.scroll_x);
                document_handler.setScrollY(pos.scroll_y);
            }
            if (pos.zoom > 0) document_handler.setActiveZoom(pos.zoom);
            document_handler.setOddShiftX(pos.odd_shift_x);
            // Last: when locked to fit-width, the zoom is recomputed at render
            // regardless of the restored value above.
            if (pos.fit_width) document_handler.setFitWidth(true);
        }
        const restored_hlock: bool = if (positions.getSavedPosition()) |p| p.hlock else false;
        var marks = positions.loadMarks(allocator);
        errdefer marks.deinit(allocator);
        var highlights = positions.loadHighlights(allocator);
        errdefer highlights.deinit(allocator);
        {
            var flat: std.ArrayList(PdfHandler.SearchHit) = .empty;
            defer flat.deinit(allocator);
            for (highlights.items) |h| {
                var i: usize = 0;
                while (i + 3 < h.rects.len) : (i += 4) {
                    flat.append(allocator, .{ .page = h.page, .x0 = h.rects[i], .y0 = h.rects[i + 1], .x1 = h.rects[i + 2], .y1 = h.rects[i + 3] }) catch break;
                }
            }
            document_handler.setHighlightQuads(flat.items);
        }

        var watcher: ?fzwatch.Watcher = null;
        if (config.file_monitor.enabled) {
            watcher = try fzwatch.Watcher.init(allocator);
            if (watcher) |*w| try w.addFile(path);
        }

        const outline = document_handler.loadOutline(allocator) catch &.{};

        // Local terminals get shared-memory raw-RGB transfer (kitty t=s: no
        // PNG encode/decode, only the shm name crosses the tty), or t=t PNG
        // temp files when disabled in config. Over SSH the terminal can't see
        // our memory or filesystem, so fall back to streaming PNG bytes.
        // zellij (>= 0.45) implements the protocol itself and rejects t=s
        // ("shared memory transfer is not supported") but reads t=t files.
        if (env.get("SSH_TTY") == null and env.get("SSH_CONNECTION") == null) {
            if (config.general.shm_transfer and env.get("ZELLIJ") == null) {
                document_handler.setTransfer(.shm, null);
            } else {
                const tmp = std.mem.trimEnd(u8, env.get("TMPDIR") orelse "/tmp", "/");
                document_handler.setTransfer(.temp_file, tmp);
            }
        }

        // The clipboard allocator must be set: without it, vaxis's parser
        // null-unwraps on any OSC 52 sequence the terminal sends back (e.g.
        // Ghostty responding around its clipboard-write confirmation), which
        // crashes the input thread. The decoded text is freed by the loop
        // since our Event union has no `paste` field.
        const vx = try vaxis.init(io, allocator, env, .{ .system_clipboard_allocator = allocator });
        const buf = try allocator.alloc(u8, 4096);
        const tty = try vaxis.Tty.init(io, buf);
        const reload_indicator_timer = ReloadIndicatorTimer.init(config);
        const history = History.init(allocator, io, env, config);

        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .page_info_text = &[_]u8{},
            .current_page = null,
            .watcher = watcher,
            .watcher_thread = null,
            .config = config,
            .loop = null,
            .current_mode = undefined,
            .history = history,
            .positions = positions,
            .doc_key = doc_key,
            .doc_abs_path = doc_abs_path,
            .outline = outline,
            .reload_page = true,
            .cache = Cache.init(allocator, config.cache.lru_size, @as(usize, config.cache.budget_mb) * 1024 * 1024),
            .reload_indicator_timer = reload_indicator_timer,
            .current_reload_indicator_state = .idle,
            .reload_indicator_active = false,
            .buf = buf,
            .visible_pages = undefined,
            .visible_pages_len = 0,
            .last_pix_per_col = 1,
            .last_pix_per_row = 1,
            .last_viewport_h_pix = 0,
            .jump_back = .empty,
            .jump_forward = .empty,
            .lock_horizontal_scroll = restored_hlock,
            .marks = marks,
            .highlights = highlights,
            .pending_op = null,
            .progress_text = null,
            .progress_buf = undefined,
            .search_hits = .empty,
            .search_needle = &.{},
            .search_index = 0,
            .prerenderer = Prerenderer.init(),
            .selection_anchor = null,
            .selection_dragged = false,
            .selection_hits = .empty,
            .selection_text = &.{},
            .selection_gen = 0,
            .selection_render_ns = 0,
            .stale_images = .empty,
            .last_save_sig = 0,
        };
    }

    pub fn saveState(self: *Self) void {
        const pos = Positions.Position{
            .page = self.document_handler.getCurrentPageNumber(),
            .scroll_x = self.document_handler.getScrollX(),
            .scroll_y = self.document_handler.getScrollY(),
            .zoom = self.document_handler.getActiveZoom(),
            .odd_shift_x = self.document_handler.getOddShiftX(),
            .colorize = self.config.general.colorize,
            .crop = self.document_handler.getCropToContent(),
            .hlock = self.lock_horizontal_scroll,
            .spread = self.document_handler.getSpread(),
            .fit_width = self.document_handler.getFitWidth(),
            .crop_left = self.document_handler.crop_left,
            .crop_right = self.document_handler.crop_right,
            .crop_top = self.document_handler.crop_top,
            .crop_bottom = self.document_handler.crop_bottom,
            .path = self.doc_abs_path,
            .last_opened = time.nowRealSeconds(),
        };
        // Most event batches change nothing persistent; skip the file
        // read-merge-write when the saved state would be identical.
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, .{
            pos.page,                          pos.scroll_x,
            pos.scroll_y,                      @as(u32, @bitCast(pos.zoom)),
            pos.odd_shift_x,                   pos.colorize,
            pos.crop,                          pos.hlock,
            pos.spread,                        pos.fit_width,
            @as(u32, @bitCast(pos.crop_left)), @as(u32, @bitCast(pos.crop_right)),
            @as(u32, @bitCast(pos.crop_top)),  @as(u32, @bitCast(pos.crop_bottom)),
        });
        for (self.marks.items) |m| {
            std.hash.autoHash(&hasher, .{ m.letter, m.page, m.scroll_x, m.scroll_y });
            hasher.update(m.comment);
        }
        for (self.highlights.items) |h| {
            std.hash.autoHash(&hasher, .{ h.page, h.text.len, h.rects.len });
        }
        const sig = hasher.final();
        if (sig == self.last_save_sig) return;
        self.last_save_sig = sig;
        self.positions.save(pos, self.marks.items, self.highlights.items);
    }

    pub fn deinit(self: *Self) void {
        // Before saveState: a mode's deinit may restore document state it
        // borrowed (e.g. crop mode zeroes the margins while active).
        self.deinitCurrentMode();
        self.saveState();
        for (self.marks.items) |m| {
            if (m.comment.len > 0) self.allocator.free(m.comment);
        }
        self.marks.deinit(self.allocator);
        for (self.highlights.items) |h| {
            if (h.text.len > 0) self.allocator.free(h.text);
            if (h.rects.len > 0) self.allocator.free(h.rects);
        }
        self.highlights.deinit(self.allocator);
        self.positions.deinit();
        self.freeOutline();
        self.search_hits.deinit(self.allocator);
        if (self.search_needle.len > 0) self.allocator.free(self.search_needle);
        self.selection_hits.deinit(self.allocator);
        if (self.selection_text.len > 0) self.allocator.free(self.selection_text);
        self.stale_images.deinit(self.allocator);
        self.allocator.free(self.doc_key);
        self.allocator.free(self.doc_abs_path);
        self.jump_back.deinit(self.allocator);
        self.jump_forward.deinit(self.allocator);
        if (self.watcher) |*w| {
            w.stop();
            if (self.watcher_thread) |thread| thread.join();
            w.deinit();
        }

        if (self.page_info_text.len > 0) self.allocator.free(self.page_info_text);

        self.reload_indicator_timer.deinit();
        self.history.deinit();
        self.prerenderer.deinit();
        self.cache.deinit();
        self.document_handler.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.config.deinit();
        self.allocator.destroy(self.config);
        self.arena.deinit();
        self.allocator.free(self.buf);
    }

    fn callback(context: ?*anyopaque, event: fzwatch.Event) void {
        switch (event) {
            .modified => {
                const loop = @as(*vaxis.Loop(Event), @ptrCast(@alignCast(context.?)));
                loop.postEvent(Event.file_changed) catch {};
            },
        }
    }

    fn watcherWorker(self: *Self, watcher: *fzwatch.Watcher) !void {
        try watcher.start(.{ .latency = self.config.file_monitor.latency });
    }

    pub fn run(self: *Self) !void {
        self.current_mode = .{ .view = ViewMode.init(self) };

        var loop: vaxis.Loop(Event) = .init(self.io, &self.tty, &self.vx);
        self.loop = &loop;
        defer self.loop = null;

        try loop.start();
        defer loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.setTitle(self.tty.writer(), std.fs.path.stem(self.doc_abs_path));
        try self.vx.queryTerminal(self.tty.writer(), std.Io.Duration.fromSeconds(1));
        if (!self.vx.caps.kitty_graphics) return error.NoKittyGraphics;
        try self.vx.setMouseMode(self.tty.writer(), true);

        self.prerenderer.context = self;
        if (self.config.cache.enabled) try self.prerenderer.start();
        // Declared after the loop defers so it runs first: the worker must be
        // joined while `loop` is still alive (it posts events to it).
        defer self.prerenderer.stop();

        if (self.config.file_monitor.enabled) {
            if (self.watcher) |*w| {
                w.setCallback(callback, &loop);
                self.watcher_thread = try std.Thread.spawn(.{}, watcherWorker, .{ self, w });
                self.current_reload_indicator_state = .watching;
                if (self.config.status_bar.enabled and self.config.file_monitor.reload_indicator_duration > 0) {
                    for (self.config.status_bar.items) |item| {
                        if (item == .reload_aware) {
                            try self.reload_indicator_timer.start(&loop);
                            self.reload_indicator_active = true;
                            break;
                        }
                    }
                }
            }
        }

        while (!self.should_quit) {
            try loop.pollEvent();

            var had_event = false;
            while (try loop.tryEvent()) |event| {
                try self.update(event);
                had_event = true;
            }

            try self.draw();

            var buffered = self.tty.writer();
            try self.vx.render(buffered);
            try buffered.flush();

            // The new frame no longer places these; delete them terminal-side
            // so big renders don't accumulate in the terminal's image store.
            if (self.stale_images.items.len > 0) {
                for (self.stale_images.items) |img| self.vx.freeImage(buffered, img.image.id);
                try buffered.flush();
                self.stale_images.clearRetainingCapacity();
            }

            // Persist position/zoom after any state-changing batch — draw() above
            // has already finalized active_zoom — so it survives a non-clean exit
            // (terminal closed, killed) without waiting for deinit on quit.
            // Not in modes that borrow document state (crop preview runs with
            // margins/oddx zeroed and transient scroll; deinit restores it).
            if (had_event and !self.modeFlag("suppress_autosave")) self.saveState();
        }
    }

    fn deinitCurrentMode(self: *Self) void {
        switch (self.current_mode) {
            .view => {},
            inline else => |*state| state.deinit(),
        }
    }

    pub fn changeMode(self: *Self, new_state: ModeType) void {
        self.deinitCurrentMode();
        switch (new_state) {
            inline else => |tag| {
                self.current_mode = @unionInit(Mode, @tagName(tag), @FieldType(Mode, @tagName(tag)).init(self));
            },
        }
    }

    pub fn resetCurrentPage(self: *Self) void {
        self.reload_page = true;
    }

    // Half the visible viewport, scrolled with a short ease-out animation.
    // Cheap: each frame only updates the kitty clip_region of the cached page
    // (no re-render), so this stays smooth even at high zoom.
    pub fn smoothScrollHalf(self: *Self, down: bool) void {
        const total_px: f32 = @floatFromInt(@max(1, self.last_viewport_h_pix / 2));
        // scrollY(dy) does pix_scroll_y -= dy, so down = negative dy.
        self.animateScrollBy(if (down) -total_px else total_px);
    }

    fn animateScrollBy(self: *Self, total_dy: f32) void {
        const frames: usize = 10;
        const frame_ns: u64 = 11 * std.time.ns_per_ms; // ~110ms total
        var applied: f32 = 0;
        var i: usize = 1;
        while (i <= frames) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frames));
            const eased = 1.0 - std.math.pow(f32, 1.0 - t, 3.0); // ease-out cubic
            const target = total_dy * eased;
            self.document_handler.scrollY(target - applied);
            applied = target;
            self.renderFrame() catch return;
            if (i < frames) time.sleep(frame_ns);
        }
    }

    pub fn renderFrame(self: *Self) !void {
        try self.draw();
        var buffered = self.tty.writer();
        try self.vx.render(buffered);
        try buffered.flush();
    }

    // Animated zoom: scale the already-transmitted placements around the
    // viewport center (no renders, ~60ms), then apply the real zoom so the
    // next draw swaps in a crisp render at the new scale.
    // Half-page jump for list popups, with the same ease-out feel as
    // smoothScrollHalf: `cursor` points at the mode's cursor field and is
    // stepped along the eased path with a redraw per frame.
    pub fn animateListCursor(self: *Self, cursor: *usize, target: usize) void {
        if (target == cursor.*) return;
        const frames: usize = 10;
        const frame_ns: u64 = 11 * std.time.ns_per_ms;
        const start: f32 = @floatFromInt(cursor.*);
        const delta: f32 = @as(f32, @floatFromInt(target)) - start;
        var i: usize = 1;
        while (i <= frames) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frames));
            const eased = 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
            const next: usize = @intFromFloat(@round(start + delta * eased));
            if (next == cursor.*) continue; // rounding duplicate: nothing to show
            cursor.* = next;
            self.renderFrame() catch return;
            if (i < frames) time.sleep(frame_ns);
        }
    }

    // Shared Ctrl-D/Ctrl-U handling for the list popups; true if consumed.
    // Callers guarantee len > 0.
    pub fn handleListHalfPage(self: *Self, key: vaxis.Key, cursor: *usize, len: usize) bool {
        const km = self.config.key_map;
        const step: usize = @max(1, self.vx.window().height / 2);
        if (key.matches(km.scroll_half_down.codepoint, km.scroll_half_down.mods)) {
            self.animateListCursor(cursor, @min(cursor.* + step, len - 1));
            return true;
        }
        if (key.matches(km.scroll_half_up.codepoint, km.scroll_half_up.mods)) {
            self.animateListCursor(cursor, cursor.* -| step);
            return true;
        }
        return false;
    }

    pub fn handleKeyStroke(self: *Self, key: vaxis.Key) !void {
        const km = self.config.key_map;

        // Global keybindings
        if (key.matches(km.quit.codepoint, km.quit.mods)) {
            self.should_quit = true;
            return;
        }

        try switch (self.current_mode) {
            inline else => |*state| state.handleKeyStroke(key, km),
        };
    }

    pub fn update(self: *Self, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                self.progress_text = null;
                try self.handleKeyStroke(key);
            },
            .mouse => |mouse| {
                switch (self.current_mode) {
                    inline else => |*m| {
                        if (comptime @hasDecl(@TypeOf(m.*), "handleMouse")) m.handleMouse(mouse);
                    },
                }
            },
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.clearCache();
                self.reload_page = true;
            },
            .file_changed => {
                try self.document_handler.reloadDocument();
                self.freeOutline();
                self.outline = self.document_handler.loadOutline(self.allocator) catch &.{};
                self.clearCache();
                self.reload_page = true;
                if (self.reload_indicator_active) {
                    self.current_reload_indicator_state = .reload;
                    self.reload_indicator_timer.notifyChange();
                }
            },
            .reload_done => {
                self.current_reload_indicator_state = .watching;
            },
            .prerender_ready => {
                self.integratePrerendered();
                self.integrateThumbs();
            },
        }
    }

    pub fn cacheKeyFor(self: *Self, page_number: u16) Cache.Key {
        return .{
            .colorize = self.config.general.colorize,
            .page = page_number,
            .width_mode = self.document_handler.getWidthMode(),
            .zoom = @as(u32, @intFromFloat(self.document_handler.getActiveZoom() * 1000.0)),
            .crop = self.document_handler.getCropToContent(),
            .spread = self.document_handler.getSpread(),
            .shift_x = if (page_number % 2 == 1) self.document_handler.getOddShiftX() else 0,
            .sel = if (self.selectionPage()) |sp| (if (sp == page_number) self.selection_gen else 0) else 0,
        };
    }

    pub fn getPage(
        self: *Self,
        page_number: u16,
        window_width: u32,
        window_height: u32,
    ) !Cache.CachedImage {
        const cache_key = self.cacheKeyFor(page_number);

        if (self.config.cache.enabled) {
            if (self.cache.get(cache_key)) |cached| return cached;
            // The page may already be prerendered but parked, its ready-event
            // still queued behind this draw. Pull results in before paying
            // for a render of our own.
            self.integratePrerendered();
            if (self.cache.get(cache_key)) |cached| return cached;
        }

        const encoded_image = try self.document_handler.renderPage(
            page_number,
            window_width,
            window_height,
        );
        defer self.allocator.free(encoded_image.data);

        const image = self.transmitEncoded(encoded_image) catch |err| {
            self.deleteEncoded(encoded_image);
            return err;
        };

        const cached = Cache.CachedImage{
            .image = image,
            .origin_x = encoded_image.origin_x,
            .origin_y = encoded_image.origin_y,
        };
        if (self.config.cache.enabled) {
            try self.cache.put(cache_key, cached, self.allocator, &self.stale_images);
        }
        return cached;
    }

    // Delivers finished background thumbs to grid mode (or discards them).
    fn integrateThumbs(self: *Self) void {
        for (self.prerenderer.claimThumbs()) |maybe| {
            const r = maybe orelse continue;
            defer {
                self.allocator.free(r.image.data);
                self.allocator.destroy(r);
            }
            if (self.current_mode != .grid or !self.current_mode.grid.wantsThumb(r.page, r.max_w)) {
                self.deleteEncoded(r.image);
                continue;
            }
            const img = self.transmitEncoded(r.image) catch {
                self.deleteEncoded(r.image);
                continue;
            };
            self.current_mode.grid.putThumb(r.page, img);
        }
    }

    pub fn requestThumbs(self: *Self, pages: [Prerenderer.thumb_slots]?u16, w: u32, h: u32) bool {
        return self.prerenderer.requestThumbs(pages, w, h);
    }

    // Renders and transmits a page thumbnail without touching reading state.
    pub fn thumbImage(self: *Self, page: u16, max_w: u32, max_h: u32) !vaxis.Image {
        const enc = try self.document_handler.renderThumb(page, max_w, max_h);
        defer self.allocator.free(enc.data);
        return self.transmitEncoded(enc) catch |err| {
            self.deleteEncoded(enc);
            return err;
        };
    }

    // Sends a render to the terminal. Locally only a name crosses the tty:
    // a shared-memory object of raw RGB (kitty t=s; the terminal unlinks it)
    // or a PNG temp-file path (t=t; the terminal deletes it). The SSH
    // fallback streams the PNG bytes base64-chunked.
    fn transmitEncoded(self: *Self, enc: PdfHandler.types.EncodedImage) !vaxis.Image {
        switch (enc.kind) {
            .shm_rgb => return self.vx.transmitLocalImagePath(
                self.allocator,
                self.tty.writer(),
                enc.data,
                enc.width,
                enc.height,
                .shared_mem,
                .rgb,
            ),
            .png_path => return self.vx.transmitLocalImagePath(
                self.allocator,
                self.tty.writer(),
                enc.data,
                enc.width,
                enc.height,
                .temp_file,
                .png,
            ),
            .png_bytes => {
                const b64 = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(enc.data.len));
                defer self.allocator.free(b64);
                const encoded = std.base64.standard.Encoder.encode(b64, enc.data);
                return self.vx.transmitPreEncodedImage(self.tty.writer(), encoded, enc.width, enc.height, .png);
            },
        }
    }

    // For renders discarded without being transmitted — the terminal will
    // never read (and so never clean up) their backing file or shm object.
    pub fn deleteEncoded(self: *Self, enc: PdfHandler.types.EncodedImage) void {
        switch (enc.kind) {
            .png_path => std.Io.Dir.cwd().deleteFile(self.io, enc.data) catch {},
            .shm_rgb => {
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{enc.data}) catch return;
                _ = std.c.shm_unlink(name.ptr);
            },
            .png_bytes => {},
        }
    }

    // Empties the render cache and queues the displaced terminal-side images
    // for deletion after the next render.
    pub fn clearCache(self: *Self) void {
        self.cache.clearInto(self.allocator, &self.stale_images);
    }

    // Pulls finished background renders in, transmitting them to the terminal
    // and caching them — unless view parameters changed while they rendered.
    fn integratePrerendered(self: *Self) void {
        for (self.prerenderer.claim()) |maybe| {
            const r = maybe orelse continue;
            defer {
                self.allocator.free(r.image.data);
                self.allocator.destroy(r);
            }
            if (!self.config.cache.enabled or
                !std.meta.eql(r.key, self.cacheKeyFor(r.key.page)) or
                self.cache.contains(r.key))
            {
                self.deleteEncoded(r.image);
                continue;
            }
            const image = self.transmitEncoded(r.image) catch {
                self.deleteEncoded(r.image);
                continue;
            };
            self.cache.put(r.key, .{
                .image = image,
                .origin_x = r.image.origin_x,
                .origin_y = r.image.origin_y,
            }, self.allocator, &self.stale_images) catch {};
        }
    }

    // Called after the draw walk, so every visible page is already cached;
    // `next_page` is where the walk stopped. Prefetches a render-ahead window of
    // up to ±3 pages (forward-biased, since reading is mostly forward) so fast
    // flipping stays cache-warm. Uncached targets only.
    fn requestPrerender(self: *Self, top_page: u16, next_page: u16, w: u32, h: u32) void {
        if (!self.config.cache.enabled) return;
        const zoom = self.document_handler.getActiveZoom();
        if (zoom <= 0) return;
        // At very high zoom a single page approaches the cache byte budget;
        // prerendered neighbors would evict each other in a render loop.
        // Require room for the current page plus two neighbors.
        const b = self.document_handler.getPageBound(top_page);
        const est_f = (b.x1 - b.x0) * zoom * (b.y1 - b.y0) * zoom * 4.0;
        if (est_f > 0 and @as(usize, @intFromFloat(est_f)) * 3 > self.cache.budget_bytes) return;

        const window = 3;
        var targets: [Prerenderer.slots]?u16 = .{null} ** Prerenderer.slots;
        var n: usize = 0;
        const total = self.document_handler.getTotalPages();

        var fwd: u32 = next_page;
        while (fwd < @min(@as(u32, next_page) + window, total) and n < targets.len) : (fwd += 1) {
            if (!self.cache.contains(self.cacheKeyFor(@intCast(fwd)))) {
                targets[n] = @intCast(fwd);
                n += 1;
            }
        }
        var back: u16 = 1;
        while (back <= window and top_page >= back and n < targets.len) : (back += 1) {
            const p = top_page - back;
            if (!self.cache.contains(self.cacheKeyFor(p))) {
                targets[n] = p;
                n += 1;
            }
        }
        if (n == 0) return;
        self.prerenderer.request(targets, w, h);
    }

    pub fn drawCurrentPage(self: *Self, win: vaxis.Window) !void {
        // Zero-size screen (e.g. during startup before the first real winsize)
        // would divide by zero below.
        if (win.screen.width == 0 or win.screen.height == 0 or
            win.screen.width_pix == 0 or win.screen.height_pix == 0) return;

        const pix_per_col = try std.math.divCeil(u16, win.screen.width_pix, win.screen.width);
        const pix_per_row = try std.math.divCeil(u16, win.screen.height_pix, win.screen.height);
        self.last_pix_per_col = pix_per_col;
        self.last_pix_per_row = pix_per_row;
        self.visible_pages_len = 0;

        var viewport_rows: u16 = win.height;
        if (self.config.status_bar.enabled or self.modeFlag("occupies_bottom_row")) viewport_rows -|= 1;
        const viewport_h_pix: u32 = @as(u32, viewport_rows) * @as(u32, pix_per_row);
        self.last_viewport_h_pix = viewport_h_pix;

        // In spread mode the strip flows through two columns; pages render at
        // full column width (flush — no gutter) and may straddle the column break.
        const columns: u16 = if (self.document_handler.getSpread()) 2 else 1;
        const col_cells: u16 = win.width / columns;
        const render_cells: u16 = col_cells;
        const render_w_pix: u32 = @as(u32, render_cells) * @as(u32, pix_per_col);

        if (self.modeFlag("hides_page")) return;

        var page_num = self.document_handler.getCurrentPageNumber();
        const total_pages = self.document_handler.getTotalPages();
        var cur = try self.getPage(page_num, render_w_pix, viewport_h_pix);

        if (self.document_handler.takePendingScrollPdfY()) |pdf_y| {
            if (!std.math.isNan(pdf_y)) {
                const zoom = self.document_handler.getActiveZoom();
                if (zoom > 0) {
                    const context_px: i32 = @intCast(@as(u32, pix_per_row) * 3);
                    const target_y: i32 = @intFromFloat((pdf_y - cur.origin_y) * zoom);
                    self.document_handler.setScrollY(@max(0, target_y - context_px));
                }
            }
        }

        var scroll_y: i32 = self.document_handler.getScrollY();

        while (scroll_y < 0 and page_num > 0) {
            const prev = try self.getPage(page_num - 1, render_w_pix, viewport_h_pix);
            scroll_y += @as(i32, @intCast(prev.image.height));
            page_num -= 1;
            cur = prev;
        }

        while (page_num + 1 < total_pages and scroll_y >= @as(i32, @intCast(cur.image.height))) {
            scroll_y -= @as(i32, @intCast(cur.image.height));
            page_num += 1;
            cur = try self.getPage(page_num, render_w_pix, viewport_h_pix);
        }

        if (page_num == 0 and scroll_y < 0) scroll_y = 0;
        if (page_num + 1 == total_pages) {
            const max_y = @max(0, @as(i32, @intCast(cur.image.height)) - @as(i32, @intCast(viewport_h_pix)));
            if (scroll_y > max_y) scroll_y = max_y;
        }

        self.document_handler.setCurrentPage(page_num);
        self.document_handler.setScrollY(scroll_y);
        self.document_handler.clampScrollX(render_w_pix);
        self.current_page = cur.image;
        self.reload_page = false;

        const scroll_x = self.document_handler.getScrollX();
        var draw_page = page_num;
        var first_top: i32 = scroll_y;

        // The strip flows column by column; (draw_page, first_top) carry across
        // the column break so a page can end mid-column-left, mid-page.
        var col: u16 = 0;
        outer: while (col < columns) : (col += 1) {
            const col_base: u16 = col * col_cells;
            var y_pix_used: u32 = 0;

            while (y_pix_used < viewport_h_pix and draw_page < total_pages) {
                const entry = try self.getPage(draw_page, render_w_pix, viewport_h_pix);
                const img = entry.image;
                const clip_top: u32 = @intCast(@max(0, first_top));
                const img_h: u32 = img.height;
                if (clip_top >= img_h) {
                    if (draw_page + 1 >= total_pages) break :outer;
                    draw_page += 1;
                    first_top = 0;
                    continue;
                }
                const remaining_vp = viewport_h_pix - y_pix_used;
                const visible_h: u32 = @min(remaining_vp, img_h - clip_top);
                if (visible_h == 0) {
                    if (draw_page + 1 >= total_pages) break :outer;
                    draw_page += 1;
                    first_top = 0;
                    continue;
                }

                const img_w: u32 = img.width;
                const need_clip_x = img_w > render_w_pix;
                const clip_w: u32 = if (need_clip_x) render_w_pix else img_w;
                const clip_x: u32 = if (need_clip_x) @intCast(@max(0, scroll_x)) else 0;

                // Slices are placed at native pixel size (no c=/r= scaling)
                // and stacked pixel-exact: a page ending mid-row leaves the
                // next page to start in that same row at a pixel offset.
                // Scaling the sub-row remainder to fill the row stretched
                // whatever text sat on the page bottom.
                const dest_cols: u16 = @intCast(@max(1, std.math.divCeil(u32, clip_w, pix_per_col) catch 1));
                const y_off: u16 = @intCast(y_pix_used / pix_per_row);
                const y_sub: u16 = @intCast(y_pix_used % pix_per_row);
                const dest_rows: u16 = @intCast(@max(1, std.math.divCeil(u32, y_sub + visible_h, pix_per_row) catch 1));
                const x_off: u16 = if (col_cells > dest_cols) (col_cells - dest_cols) / 2 else 0;

                const child = win.child(.{
                    .x_off = col_base + x_off,
                    .y_off = y_off,
                    .width = dest_cols,
                    .height = dest_rows,
                });
                try img.draw(child, .{
                    .clip_region = .{
                        .x = @intCast(clip_x),
                        .y = @intCast(clip_top),
                        .width = @intCast(clip_w),
                        .height = @intCast(visible_h),
                    },
                    .pixel_offset = if (y_sub > 0) .{ .x = 0, .y = y_sub } else null,
                    .z_index = if (self.modeFlag("page_behind_text")) -1 else null,
                });
                if (self.visible_pages_len < self.visible_pages.len) {
                    const vp_x_left: u32 = @as(u32, col_base + x_off) * @as(u32, pix_per_col);
                    self.visible_pages[self.visible_pages_len] = .{
                        .page_num = draw_page,
                        .vp_y_top = y_pix_used,
                        .vp_y_bot = y_pix_used + visible_h,
                        .vp_x_left = vp_x_left,
                        .vp_x_right = vp_x_left + clip_w,
                        .clip_x = clip_x,
                        .clip_y = clip_top,
                        .origin_x = entry.origin_x,
                        .origin_y = entry.origin_y,
                    };
                    self.visible_pages_len += 1;
                }

                y_pix_used += visible_h;
                if (clip_top + visible_h < img_h) {
                    // page continues — into this column's remainder or the next column
                    first_top = @intCast(clip_top + visible_h);
                } else {
                    if (draw_page + 1 >= total_pages) break :outer;
                    draw_page += 1;
                    first_top = 0;
                }
            }
        }

        self.requestPrerender(page_num, draw_page, render_w_pix, viewport_h_pix);
    }

    // Maps a mouse cell position to the page and raw PDF coordinates under it.
    pub fn pdfPointAt(self: *Self, mouse: vaxis.Mouse) ?PagePoint {
        // Coordinates are negative when the event is outside our pane (e.g.
        // clicking another terminal split).
        if (mouse.col < 0 or mouse.row < 0) return null;
        const pix_x: u32 = @as(u32, @intCast(mouse.col)) * @as(u32, self.last_pix_per_col) + mouse.xoffset;
        const pix_y: u32 = @as(u32, @intCast(mouse.row)) * @as(u32, self.last_pix_per_row) + mouse.yoffset;
        const zoom = self.document_handler.getActiveZoom();
        if (zoom == 0) return null;

        for (self.visible_pages[0..self.visible_pages_len]) |p| {
            if (pix_y < p.vp_y_top or pix_y >= p.vp_y_bot) continue;
            if (pix_x < p.vp_x_left or pix_x >= p.vp_x_right) continue;

            const bitmap_x: f32 = @floatFromInt(p.clip_x + (pix_x - p.vp_x_left));
            const bitmap_y: f32 = @floatFromInt(p.clip_y + (pix_y - p.vp_y_top));
            var pdf_x = bitmap_x / zoom + p.origin_x;
            const pdf_y = bitmap_y / zoom + p.origin_y;
            // The bitmap is in aligned space; page content is in raw page coords.
            if (p.page_num % 2 == 1) pdf_x -= @as(f32, @floatFromInt(self.document_handler.getOddShiftX()));
            return .{ .page = p.page_num, .x = pdf_x, .y = pdf_y };
        }
        return null;
    }

    pub fn handleLeftClick(self: *Self, mouse: vaxis.Mouse) !void {
        const pt = self.pdfPointAt(mouse) orelse return;
        const target = self.document_handler.findLinkAtPoint(self.allocator, pt.page, pt.x, pt.y) orelse return;
        defer if (target == .uri) self.allocator.free(target.uri);
        self.followLink(target);
    }

    fn selectionPage(self: *Self) ?u16 {
        if (self.selection_hits.items.len == 0) return null;
        return self.selection_hits.items[0].page;
    }

    // Drops the current selection-generation cache entry. Stale generations
    // would otherwise squat in the LRU and evict prerendered neighbor pages.
    fn dropSelectionEntry(self: *Self) void {
        const sp = self.selectionPage() orelse return;
        if (self.cache.take(self.cacheKeyFor(sp))) |old| {
            self.stale_images.append(self.allocator, old) catch {};
        }
    }

    pub fn updateSelection(self: *Self, anchor: PagePoint, head: PagePoint) void {
        self.selection_hits.clearRetainingCapacity();
        if (self.selection_text.len > 0) {
            self.allocator.free(self.selection_text);
            self.selection_text = &.{};
        }
        self.selection_text = self.document_handler.selectText(
            self.allocator,
            anchor.page,
            anchor.x,
            anchor.y,
            head.x,
            head.y,
            &self.selection_hits,
        ) catch &.{};
        self.document_handler.setSelectionQuads(self.selection_hits.items);
        // Each re-render at high zoom is a multi-MB image transmit; during a
        // drag, refresh the visual at most a few times per second. The state
        // above is always current, so the release still copies exact text.
        const now = time.nowNs();
        if (now - self.selection_render_ns >= 250 * std.time.ns_per_ms) {
            self.selection_render_ns = now;
            self.dropSelectionEntry();
            self.selection_gen +%= 1;
            self.reload_page = true;
        }
    }

    pub fn clearSelection(self: *Self) void {
        if (self.selection_hits.items.len == 0 and self.selection_text.len == 0) return;
        self.dropSelectionEntry();
        self.selection_hits.clearRetainingCapacity();
        if (self.selection_text.len > 0) {
            self.allocator.free(self.selection_text);
            self.selection_text = &.{};
        }
        self.document_handler.setSelectionQuads(&.{});
        self.reload_page = true;
    }

    pub fn finishSelection(self: *Self) void {
        if (self.selection_text.len == 0) return;
        const w = self.tty.writer();
        self.vx.copyToSystemClipboard(w, self.selection_text, self.allocator) catch {};
        w.flush() catch {};
        // The throttle above may have skipped the last drag updates; render
        // the final selection state.
        self.dropSelectionEntry();
        self.selection_gen +%= 1;
        self.reload_page = true;
        // Shown until the next keypress clears progress_text.
        const msg = std.fmt.bufPrint(&self.progress_buf, " copied {d} chars ", .{self.selection_text.len}) catch return;
        self.progress_text = msg;
    }

    fn rebuildHighlightQuads(self: *Self) void {
        var flat: std.ArrayList(PdfHandler.SearchHit) = .empty;
        defer flat.deinit(self.allocator);
        for (self.highlights.items) |h| {
            var i: usize = 0;
            while (i + 3 < h.rects.len) : (i += 4) {
                flat.append(self.allocator, .{ .page = h.page, .x0 = h.rects[i], .y0 = h.rects[i + 1], .x1 = h.rects[i + 2], .y1 = h.rects[i + 3] }) catch break;
            }
        }
        self.document_handler.setHighlightQuads(flat.items);
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

    pub fn addHighlightFromSelection(self: *Self) void {
        if (self.selection_hits.items.len == 0) return;
        const page = self.selection_hits.items[0].page;

        var collected: std.ArrayList(f32) = .empty;
        defer collected.deinit(self.allocator);
        for (self.selection_hits.items) |q| {
            collected.appendSlice(self.allocator, &.{ q.x0, q.y0, q.x1, q.y1 }) catch return;
        }

        // Absorb every existing highlight on this page that overlaps the
        // growing union (re-scanning so chains of overlaps merge too).
        var merged_any = false;
        var scan_again = true;
        while (scan_again) {
            scan_again = false;
            var i: usize = 0;
            while (i < self.highlights.items.len) : (i += 1) {
                const h = self.highlights.items[i];
                if (h.page != page or !rectsOverlap(h.rects, collected.items)) continue;
                collected.appendSlice(self.allocator, h.rects) catch return;
                if (h.text.len > 0) self.allocator.free(h.text);
                if (h.rects.len > 0) self.allocator.free(h.rects);
                _ = self.highlights.orderedRemove(i);
                merged_any = true;
                scan_again = true;
                break;
            }
        }

        var text: []const u8 = "";
        var rects: []f32 = &.{};
        if (merged_any) {
            // Re-select from the union's first to last point in reading order:
            // exact merged text plus clean per-line quads.
            var first: [2]f32 = .{ collected.items[0], (collected.items[1] + collected.items[3]) / 2 };
            var last: [2]f32 = .{ collected.items[2], (collected.items[1] + collected.items[3]) / 2 };
            var i: usize = 4;
            while (i + 3 < collected.items.len) : (i += 4) {
                const cy = (collected.items[i + 1] + collected.items[i + 3]) / 2;
                if (cy < first[1] or (cy == first[1] and collected.items[i] < first[0])) first = .{ collected.items[i], cy };
                if (cy > last[1] or (cy == last[1] and collected.items[i + 2] > last[0])) last = .{ collected.items[i + 2], cy };
            }
            var merged_hits: std.ArrayList(PdfHandler.SearchHit) = .empty;
            defer merged_hits.deinit(self.allocator);
            const merged_text = self.document_handler.selectText(
                self.allocator,
                page,
                first[0] + 1,
                first[1],
                last[0] - 1,
                last[1],
                &merged_hits,
            ) catch &.{};
            if (merged_hits.items.len > 0) {
                rects = self.allocator.alloc(f32, merged_hits.items.len * 4) catch return;
                for (merged_hits.items, 0..) |q, qi| {
                    rects[qi * 4] = q.x0;
                    rects[qi * 4 + 1] = q.y0;
                    rects[qi * 4 + 2] = q.x1;
                    rects[qi * 4 + 3] = q.y1;
                }
                text = merged_text;
            } else {
                // Re-selection failed (e.g. non-text region): keep the raw union.
                if (merged_text.len > 0) self.allocator.free(merged_text);
                rects = self.allocator.dupe(f32, collected.items) catch return;
                text = self.allocator.dupe(u8, self.selection_text) catch "";
            }
        } else {
            rects = self.allocator.dupe(f32, collected.items) catch return;
            text = self.allocator.dupe(u8, self.selection_text) catch "";
        }

        self.highlights.append(self.allocator, .{ .page = page, .text = text, .rects = rects }) catch {
            self.allocator.free(rects);
            if (text.len > 0) self.allocator.free(@constCast(text));
            return;
        };
        self.clearSelection();
        self.rebuildHighlightQuads();
        self.clearCache();
        self.reload_page = true;
        const msg = std.fmt.bufPrint(&self.progress_buf, " highlighted ({d} total{s}) ", .{
            self.highlights.items.len,
            if (merged_any) ", merged" else "",
        }) catch return;
        self.progress_text = msg;
    }

    pub fn deleteHighlight(self: *Self, idx: usize) void {
        if (idx >= self.highlights.items.len) return;
        const h = self.highlights.orderedRemove(idx);
        if (h.text.len > 0) self.allocator.free(h.text);
        if (h.rects.len > 0) self.allocator.free(h.rects);
        self.rebuildHighlightQuads();
        self.clearCache();
        self.reload_page = true;
    }

    // Jump to `page` scrolled so pdf_y sits near the viewport top.
    pub fn gotoPagePdfY(self: *Self, page: u16, pdf_y: f32) void {
        self.document_handler.setCurrentPage(page);
        self.document_handler.setScrollY(0);
        self.document_handler.setPendingScrollPdfY(pdf_y);
        self.resetCurrentPage();
    }

    pub fn jumpToHighlight(self: *Self, idx: usize) void {
        if (idx >= self.highlights.items.len) return;
        const h = self.highlights.items[idx];
        self.pushJump();
        self.gotoPagePdfY(h.page, if (h.rects.len >= 2) h.rects[1] else 0);
    }

    // Esc in view mode: drop the selection first; a second Esc clears search.
    pub fn escapeClear(self: *Self) void {
        if (self.selection_hits.items.len > 0) {
            self.clearSelection();
            return;
        }
        self.clearSearch();
    }

    // Does not take ownership of a .uri target; the caller frees it.
    pub fn followLink(self: *Self, target: PdfHandler.LinkTarget) void {
        switch (target) {
            .page => |dest| {
                self.pushJump();
                _ = self.document_handler.goToPage(dest.num + 1);
                self.document_handler.setScrollY(0);
                self.document_handler.setPendingScrollPdfY(dest.y);
                self.resetCurrentPage();
            },
            .uri => |uri| {
                _ = std.process.spawn(self.io, .{
                    .argv = &.{ "open", uri },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch {};
            },
        }
    }

    fn currentPosition(self: *Self) JumpPosition {
        return .{
            .page = self.document_handler.getCurrentPageNumber(),
            .scroll_y = self.document_handler.getScrollY(),
            .scroll_x = self.document_handler.getScrollX(),
        };
    }

    pub fn pushJump(self: *Self) void {
        const pos = self.currentPosition();
        self.jump_back.append(self.allocator, pos) catch return;
        if (self.jump_back.items.len > max_jumps) _ = self.jump_back.orderedRemove(0);
        self.jump_forward.clearRetainingCapacity();
    }

    pub fn jumpBack(self: *Self) void {
        const target = self.jump_back.pop() orelse return;
        const here = self.currentPosition();
        self.jump_forward.append(self.allocator, here) catch {};
        self.restorePosition(target);
    }

    pub fn jumpForward(self: *Self) void {
        const target = self.jump_forward.pop() orelse return;
        const here = self.currentPosition();
        self.jump_back.append(self.allocator, here) catch {};
        self.restorePosition(target);
    }

    fn restorePosition(self: *Self, pos: JumpPosition) void {
        self.document_handler.setCurrentPage(pos.page);
        self.document_handler.setScrollY(pos.scroll_y);
        self.document_handler.setScrollX(pos.scroll_x);
        self.resetCurrentPage();
    }

    pub fn setMark(self: *Self, letter: u8) void {
        const page = self.document_handler.getCurrentPageNumber();
        const sx = self.document_handler.getScrollX();
        const sy = self.document_handler.getScrollY();
        for (self.marks.items) |*m| {
            if (m.letter == letter) {
                m.page = page;
                m.scroll_x = sx;
                m.scroll_y = sy;
                if (m.comment.len > 0) {
                    self.allocator.free(m.comment);
                    m.comment = "";
                }
                return;
            }
        }
        self.marks.append(self.allocator, .{
            .letter = letter,
            .page = page,
            .scroll_x = sx,
            .scroll_y = sy,
        }) catch {};
    }

    pub fn jumpToMark(self: *Self, letter: u8) void {
        for (self.marks.items) |m| {
            if (m.letter == letter) {
                if (m.page < self.document_handler.getTotalPages()) {
                    self.pushJump();
                    self.document_handler.setCurrentPage(m.page);
                    self.document_handler.setScrollX(m.scroll_x);
                    self.document_handler.setScrollY(m.scroll_y);
                    self.resetCurrentPage();
                }
                return;
            }
        }
    }

    pub fn deleteMark(self: *Self, letter: u8) void {
        for (self.marks.items, 0..) |m, i| {
            if (m.letter == letter) {
                if (m.comment.len > 0) self.allocator.free(m.comment);
                _ = self.marks.orderedRemove(i);
                return;
            }
        }
    }

    // `:export [path]` — cropped/aligned copy of the PDF for printing.
    pub fn exportCropped(self: *Self, arg: []const u8) void {
        var path_buf: [1024]u8 = undefined;
        const out: [:0]const u8 = blk: {
            if (arg.len > 0) break :blk std.fmt.bufPrintZ(&path_buf, "{s}", .{arg}) catch {
                self.progress_text = " export: path too long ";
                return;
            };
            const dir = std.fs.path.dirname(self.doc_abs_path) orelse ".";
            const stem = std.fs.path.stem(self.doc_abs_path);
            break :blk std.fmt.bufPrintZ(&path_buf, "{s}/{s}-cropped.pdf", .{ dir, stem }) catch {
                self.progress_text = " export: path too long ";
                return;
            };
        };
        self.document_handler.exportCropped(out, false) catch |err| {
            self.progress_text = switch (err) {
                error.NothingToApply => " export: no crop or oddx set ",
                else => " export failed ",
            };
            return;
        };
        const msg = std.fmt.bufPrint(&self.progress_buf, " exported {s} ", .{out}) catch " exported ";
        self.progress_text = msg;
    }

    // `:override` — bake the crop + oddx into the file itself (same /ID, so
    // saved state stays attached), then reset that state: the next open lands
    // on the same page but relies on the document's own boxes.
    pub fn overrideCropped(self: *Self) void {
        var tmp_buf: [1024]u8 = undefined;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.override.tmp", .{self.doc_abs_path}) catch {
            self.progress_text = " override: path too long ";
            return;
        };
        const page = self.document_handler.getCurrentPageNumber();
        // The save reads the source lazily, so it must go to a temp file and
        // rename over the original rather than write in place.
        self.document_handler.exportCropped(tmp, true) catch |err| {
            self.progress_text = switch (err) {
                error.NothingToApply => " override: no crop or oddx set ",
                else => " override failed ",
            };
            return;
        };
        std.Io.Dir.renameAbsolute(tmp, self.doc_abs_path, self.io) catch {
            self.progress_text = " override: rename failed ";
            return;
        };
        // The file carries the geometry now; drop it from the session state.
        if (self.document_handler.getCropToContent()) self.document_handler.toggleCropToContent();
        self.document_handler.setMarginCrop(0, 0, 0, 0);
        self.document_handler.setOddShiftX(0);
        self.document_handler.reloadDocument() catch {};
        self.freeOutline();
        self.outline = self.document_handler.loadOutline(self.allocator) catch &.{};
        self.clearCache();
        self.document_handler.setCurrentPage(page);
        self.resetCurrentPage();
        self.saveState();
        self.progress_text = " crop baked into file; saved state reset ";
    }

    pub fn openCurrentPageInEditor(self: *Self) !void {
        const page = self.document_handler.getCurrentPageNumber();
        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/termre-{d}-page{d}", .{ pid, page + 1 });
        defer self.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/page{d}.md", .{ dir, page + 1 }, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        try self.document_handler.writePageText(page, path);
        try self.spawnEditorAndWait(path, dir, null);
    }

    fn freeOutline(self: *Self) void {
        for (self.outline) |e| self.allocator.free(e.title);
        if (self.outline.len > 0) self.allocator.free(self.outline);
        self.outline = &.{};
    }

    // Title of the deepest outline entry at or before `page` ("current section").
    pub fn chapterFor(self: *Self, page: u16) []const u8 {
        var title: []const u8 = "";
        for (self.outline) |e| {
            if (e.page > page) break;
            title = e.title;
        }
        return title;
    }

    fn currentChapterRange(self: *Self, current_page: u16) struct { start: u16, end: u16 } {
        const total = self.document_handler.getTotalPages();
        const entries = self.outline;
        if (entries.len == 0) return .{ .start = current_page, .end = current_page + 1 };

        var min_depth: u8 = 255;
        for (entries) |e| {
            if (e.depth < min_depth) min_depth = e.depth;
        }

        var start: u16 = 0;
        var end: u16 = total;
        var found = false;
        for (entries, 0..) |e, i| {
            if (e.depth != min_depth) continue;
            if (e.page <= current_page) {
                start = e.page;
                found = true;
                end = total;
                for (entries[i + 1 ..]) |next_e| {
                    if (next_e.depth == min_depth) {
                        end = next_e.page;
                        break;
                    }
                }
            } else break;
        }
        if (!found) return .{ .start = current_page, .end = current_page + 1 };
        return .{ .start = start, .end = end };
    }

    fn flashProgress(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.progress_buf, fmt, args) catch return;
        self.progress_text = msg;
        const win = self.vx.window();
        // This renders mid-update without a full repaint, so every screen cell
        // it leaves in place must still reference live memory. Callers that
        // freed text backing on-screen cells (e.g. TextInput's toOwnedSlice)
        // must repaint those cells before triggering a flash.
        self.drawStatusBar(win) catch return;
        var w = self.tty.writer();
        self.vx.render(w) catch return;
        w.flush() catch return;
    }

    fn progressCallback(ud: ?*anyopaque, current: c_int, total: c_int) callconv(.c) void {
        const self = @as(*Self, @ptrCast(@alignCast(ud.?)));
        self.flashProgress(" Rendering chapter {d}/{d} ", .{ current, total });
    }

    fn extractRangeToEditor(self: *Self, dir: []const u8, name: []const u8, start: u16, end: u16) !void {
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ dir, name }, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        try self.document_handler.writePagesText(start, end, path, progressCallback, self);
        self.progress_text = null;
        try self.spawnEditorAndWait(path, dir, null);
    }

    pub fn openCurrentChapterInEditor(self: *Self) !void {
        const page = self.document_handler.getCurrentPageNumber();
        const range = self.currentChapterRange(page);
        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/termre-{d}-chap-{d}-{d}", .{ pid, range.start + 1, range.end });
        defer self.allocator.free(dir);
        const name = try std.fmt.allocPrint(self.allocator, "chap-{d}-{d}.md", .{ range.start + 1, range.end });
        defer self.allocator.free(name);

        try self.extractRangeToEditor(dir, name, range.start, range.end);
    }

    pub fn openOutlineInEditor(self: *Self, selected_index: ?usize) !void {
        const entries = self.outline;
        if (entries.len == 0) return;

        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/termre-{d}-toc", .{pid});
        defer self.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/toc.md", .{dir}, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        {
            var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
            defer file.close(self.io);
            var buf: [4096]u8 = undefined;
            var fw = file.writer(self.io, &buf);
            const w = &fw.interface;
            try w.writeAll("# Table of Contents\n\n");
            for (entries) |e| {
                var k: usize = 0;
                while (k < @as(usize, e.depth) * 2) : (k += 1) try w.writeByte(' ');
                try w.print("- {s}  (p.{d})\n", .{ e.title, e.page + 1 });
            }
            try w.flush();
        }
        const line: ?usize = if (selected_index) |i| i + 3 else null; // header is 2 lines; entries start at line 3
        try self.spawnEditorAndWait(path, dir, line);
    }

    fn spawnEditorAndWait(self: *Self, path: [:0]const u8, dir: []const u8, line: ?usize) !void {
        var writer = self.tty.writer();
        try self.vx.setMouseMode(writer, false);
        try self.vx.exitAltScreen(writer);
        try writer.flush();

        // Release the tty so the editor can read stdin — otherwise the vaxis
        // input thread keeps consuming keystrokes from underneath the editor.
        if (self.loop) |loop| loop.stop();

        const editor_raw = self.env.get("EDITOR") orelse self.env.get("VISUAL") orelse "vim";
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        var it = std.mem.tokenizeAny(u8, editor_raw, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.allocator, tok);

        // Jump vim-family editors to a specific line (e.g. the TOC's selected
        // chapter). `+N` is understood by vi/vim/nvim/nano/emacs; skip it for
        // others (e.g. `code` would treat `+N` as a filename).
        var line_buf: ?[]u8 = null;
        defer if (line_buf) |lb| self.allocator.free(lb);
        if (line) |n| {
            if (argv.items.len > 0) {
                const base = std.fs.path.basename(argv.items[0]);
                const is_vi = std.mem.eql(u8, base, "vim") or std.mem.eql(u8, base, "nvim") or
                    std.mem.eql(u8, base, "vi") or std.mem.eql(u8, base, "nano") or
                    std.mem.eql(u8, base, "emacs") or std.mem.eql(u8, base, "emacsclient");
                if (is_vi) {
                    line_buf = try std.fmt.allocPrint(self.allocator, "+{d}", .{n});
                    try argv.append(self.allocator, line_buf.?);
                }
            }
        }
        try argv.append(self.allocator, path);

        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = self.env,
        });
        _ = child.wait(self.io) catch {};

        // Clean up the per-extract directory and everything inside it.
        const last_slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse 0;
        const parent = dir[0..last_slash];
        const leaf = dir[last_slash + 1 ..];
        if (std.Io.Dir.openDirAbsolute(self.io, parent, .{})) |opened_parent| {
            var parent_dir = opened_parent;
            defer parent_dir.close(self.io);
            parent_dir.deleteTree(self.io, leaf) catch {};
        } else |_| {}

        if (self.loop) |loop| try loop.start();

        try self.vx.enterAltScreen(writer);
        // Re-measure: the alt screen was torn down and rebuilt while the editor
        // owned the tty, so screen.width_pix/height_pix are stale. Without this
        // the fit-zoom renders slightly small until the next SIGWINCH. Mirrors
        // the startup query; must run after loop.start() (input thread alive).
        try self.vx.queryTerminal(writer, std.Io.Duration.fromSeconds(1));
        try self.vx.setMouseMode(writer, true);
        try writer.flush();
        self.clearCache();
        self.reload_page = true;
    }

    pub fn enterCommandWithText(self: *Self, text: []const u8) void {
        self.changeMode(.command);
        self.current_mode.command.text_input.insertSliceAtCursor(text) catch {};
    }

    pub fn setMarkComment(self: *Self, letter: u8, comment: []const u8) !void {
        for (self.marks.items) |*m| {
            if (m.letter == letter) {
                if (m.comment.len > 0) self.allocator.free(m.comment);
                m.comment = try self.allocator.dupe(u8, comment);
                return;
            }
        }
    }

    pub fn drawStatusBar(self: *Self, win: vaxis.Window) !void {
        const arena = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);

        const status_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height -| 1,
            .width = win.width,
            .height = 1,
        });

        if (self.progress_text) |text| {
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
            _ = status_bar.print(&.{.{ .text = text, .style = self.config.status_bar.style }}, .{ .col_offset = 0 });
            return;
        }

        // Expand all items into styled sub-items
        var expanded_items: std.ArrayList(Config.StatusBar.StyledItem) = .empty;

        for (self.config.status_bar.items) |item| {
            const styled = switch (item) {
                .styled => |styled| styled,
                .mode_aware => |mode_aware| switch (self.current_mode) {
                    .command => mode_aware.command,
                    else => mode_aware.view,
                },
                .reload_aware => |reload_aware| switch (self.current_reload_indicator_state) {
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
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
        }

        // Left side
        var left_col: usize = 0;
        for (0..separator_index) |i| {
            try self.drawStatusText(status_bar, items[i], &left_col, true, arena);
        }

        // Right side
        if (separator_index < items.len - 1) {
            var right_col: usize = win.width;
            for (0..(items.len - separator_index - 1)) |j| {
                try self.drawStatusText(status_bar, items[items.len - 1 - j], &right_col, false, arena);
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

    pub fn runSearch(self: *Self, needle: []const u8) !void {
        self.clearSearch();
        if (needle.len == 0) return;
        self.search_needle = try self.allocator.dupe(u8, needle);
        const needle_z = try self.allocator.dupeZ(u8, needle);
        defer self.allocator.free(needle_z);

        const total = self.document_handler.getTotalPages();
        var page: u16 = 0;
        while (page < total) : (page += 1) {
            if (page % 64 == 0 and total > 128) {
                self.flashProgress(" Searching {d}/{d} ", .{ page + 1, total });
            }
            try self.document_handler.searchPage(self.allocator, page, needle_z, &self.search_hits);
        }
        self.progress_text = null;
        self.document_handler.setSearchHighlights(self.search_hits.items);
        self.clearCache();
        self.reload_page = true;
        if (self.search_hits.items.len == 0) return;

        const cur = self.document_handler.getCurrentPageNumber();
        self.search_index = 0;
        for (self.search_hits.items, 0..) |h, i| {
            if (h.page >= cur) {
                self.search_index = i;
                break;
            }
        }
        self.gotoHit(self.search_index);
    }

    pub fn clearSearch(self: *Self) void {
        if (self.search_hits.items.len == 0 and self.search_needle.len == 0) return;
        self.search_hits.clearRetainingCapacity();
        self.document_handler.setSearchHighlights(&.{});
        if (self.search_needle.len > 0) {
            self.allocator.free(self.search_needle);
            self.search_needle = &.{};
        }
        self.search_index = 0;
        self.clearCache();
        self.reload_page = true;
    }

    pub fn gotoHit(self: *Self, index: usize) void {
        const h = self.search_hits.items[index];
        self.pushJump();
        self.document_handler.setCurrentPage(h.page);
        self.document_handler.setScrollY(0);
        self.document_handler.setPendingScrollPdfY(h.y0);
        self.resetCurrentPage();
    }

    pub fn searchNext(self: *Self) void {
        const n = self.search_hits.items.len;
        if (n == 0) return;
        self.search_index = (self.search_index + 1) % n;
        self.gotoHit(self.search_index);
    }

    pub fn searchPrev(self: *Self) void {
        const n = self.search_hits.items.len;
        if (n == 0) return;
        self.search_index = if (self.search_index == 0) n - 1 else self.search_index - 1;
        self.gotoHit(self.search_index);
    }

    fn stripDirPrefix(path: []const u8, dir: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, dir)) return null;
        var rel = path[dir.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }

    fn drawStatusText(self: *Self, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
        var text = item.text;

        if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
            const cwd_dir = std.Io.Dir.cwd();
            const cwd = try cwd_dir.realPathFileAlloc(self.io, ".", allocator);
            defer allocator.free(cwd);

            const full_path = try cwd_dir.realPathFileAlloc(self.io, self.document_handler.getPath(), allocator);
            defer allocator.free(full_path);

            if (stripDirPrefix(full_path, cwd)) |rel| {
                text = try allocator.dupe(u8, rel);
            } else if (self.env.get("HOME")) |home| {
                if (stripDirPrefix(full_path, home)) |rel| {
                    text = try std.fmt.allocPrint(allocator, "~/{s}", .{rel});
                } else {
                    text = try allocator.dupe(u8, full_path);
                }
            } else {
                text = try allocator.dupe(u8, full_path);
            }
        } else if (std.mem.eql(u8, text, Config.StatusBar.PAGE)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getCurrentPageNumber() + 1});
        } else if (std.mem.eql(u8, text, Config.StatusBar.TOTAL_PAGES)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getTotalPages()});
        } else if (std.mem.eql(u8, text, Config.StatusBar.SEPARATOR)) {
            text = "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.HLOCK)) {
            text = if (self.lock_horizontal_scroll) " HLOCK " else "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.FIT)) {
            text = if (self.document_handler.getFitWidth()) " FIT " else "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.ODDX)) {
            const oddx = self.document_handler.getOddShiftX();
            text = if (oddx != 0)
                try std.fmt.allocPrint(allocator, " ODDX {d} ", .{oddx})
            else
                "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.CROP)) {
            // CSS order (T R B L), matching what :crop accepts.
            text = if (self.document_handler.cropInfo()) |ci|
                try std.fmt.allocPrint(allocator, " CROP{s} {d:.0} {d:.0} {d:.0} {d:.0} ", .{
                    if (ci.auto) "*" else "", ci.top, ci.right, ci.bottom, ci.left,
                })
            else
                "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.CHAPTER)) {
            text = self.chapterFor(self.document_handler.getCurrentPageNumber());
        } else if (std.mem.eql(u8, text, Config.StatusBar.PERCENT)) {
            const total = self.document_handler.getTotalPages();
            const pct = if (total > 0) (@as(u32, self.document_handler.getCurrentPageNumber()) + 1) * 100 / total else 0;
            text = try std.fmt.allocPrint(allocator, "{d}", .{pct});
        } else if (std.mem.eql(u8, text, Config.StatusBar.SEARCH)) {
            text = if (self.search_hits.items.len > 0)
                try std.fmt.allocPrint(allocator, " {d}/{d} {s} ", .{ self.search_index + 1, self.search_hits.items.len, self.search_needle })
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

    pub fn draw(self: *Self) !void {
        const win = self.vx.window();
        win.clear();

        try self.drawCurrentPage(win);

        if (self.current_mode == .command) {
            self.current_mode.command.drawCommandBar(win);
        } else if (self.current_mode == .search) {
            self.current_mode.search.drawSearchBar(win);
        } else if (self.config.status_bar.enabled) {
            try self.drawStatusBar(win);
        }
        switch (self.current_mode) {
            inline else => |*m| {
                if (comptime @hasDecl(@TypeOf(m.*), "draw")) m.draw(win);
            },
        }
    }

    // Reads a mode's comptime trait flag (e.g. `pub const hides_page = true;`)
    // so modes declare their behavior instead of Context keeping per-mode lists.
    fn modeFlag(self: *Self, comptime flag: []const u8) bool {
        return switch (self.current_mode) {
            inline else => |*m| comptime if (@hasDecl(@TypeOf(m.*), flag)) @field(@TypeOf(m.*), flag) else false,
        };
    }

    pub fn toggleFullScreen(self: *Self) void {
        self.config.status_bar.enabled = !self.config.status_bar.enabled;
    }
};
