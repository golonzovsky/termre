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
const Paths = @import("services/Paths.zig");
const Sync = @import("services/Sync.zig");
const Prerenderer = @import("services/Prerenderer.zig");
const StatusBar = @import("StatusBar.zig");
const Selection = @import("Selection.zig");
const time = @import("utilities/time.zig");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    file_changed,
    reload_done,
    prerender_ready,
    sync: Sync.Result,
    // From the command inbox (an agent's goto_page); owned, freed by the handler.
    control: []u8,
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
    watcher: ?fzwatch.Watcher,
    watcher_thread: ?std.Thread,
    config: *Config,
    loop: ?*vaxis.Loop(Event),
    current_mode: Mode,
    next_mode: ?ModeType = null,
    pending_command_text: ?[]u8 = null,
    history: History,
    positions: Positions,
    doc_key: []u8,
    doc_abs_path: [:0]u8,
    paths: Paths,
    status_path: []u8,
    outline: []const PdfHandler.OutlineEntry,
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
    // Grid-mode thumbnail size (cells); lives here so it survives mode switches.
    grid_cell_w: u16,
    marks: std.ArrayList(Positions.Mark),
    highlights: std.ArrayList(Positions.Highlight),
    tombstones: std.ArrayList(Positions.Tombstone),
    sync: ?*Sync,
    sync_manual: bool,
    sync_stopped: bool,
    cache_gen: std.atomic.Value(u32),
    // The reader changed the view (or opened at an explicit page) this
    // session; recorded so an opened-but-untouched record can't outrank it.
    view_touched: bool,
    saved_once: bool,
    save_warned: bool = false,
    control_quit: std.atomic.Value(bool),
    control_thread: ?std.Thread,
    presence: Positions.Presence,
    // Timestamp of the view state we last saved or adopted; a pulled view
    // only replaces ours when it is newer than this.
    last_view_ts: i64,
    pending_op: ?enum { set_mark, jump_mark, spread_digit },
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

        const doc_abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(doc_abs_path);
        const status_path = try StatusBar.displayPath(allocator, io, env, doc_abs_path);
        errdefer allocator.free(status_path);

        const paths = try Paths.init(allocator, env, config);
        errdefer paths.deinit(allocator);
        var positions = Positions.init(allocator, io, paths, doc_key);
        errdefer positions.deinit();
        // An explicit page argument overrides only the position; view settings
        // (zoom/crop/spread/...) are always restored, otherwise the next
        // auto-save would overwrite them with defaults.
        if (positions.getSavedPositionForKey(document_handler.getPath())) |pos| {
            applyView(&document_handler, config, pos, initial_page == null);
        }
        const restored_hlock: bool = if (positions.getSavedPosition()) |p| p.hlock else false;
        const restored_grid: u16 = if (positions.getSavedPosition()) |p|
            (if (p.grid_zoom >= 12 and p.grid_zoom <= 64) p.grid_zoom else 24)
        else
            24;
        var marks = positions.loadMarks(allocator);
        errdefer marks.deinit(allocator);
        var highlights = positions.loadHighlights(allocator);
        errdefer highlights.deinit(allocator);
        var tombstones = positions.loadTombstones(allocator);
        errdefer tombstones.deinit(allocator);
        const last_view_ts: i64 = if (positions.getSavedPosition()) |p| p.last_opened else 0;
        const sync = makeSync(allocator, io, env, config, &positions);
        Selection.applyHighlightQuads(allocator, &document_handler, highlights.items);

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
        // zellij (>= 0.45) and Rex implement the protocol themselves and reject
        // t=s ("shared memory transfer is not supported") but read t=t files.
        const in_rex = if (env.get("TERM_PROGRAM")) |tp| std.mem.eql(u8, tp, "rex") else false;
        if (env.get("SSH_TTY") == null and env.get("SSH_CONNECTION") == null) {
            if (config.general.shm_transfer and env.get("ZELLIJ") == null and !in_rex) {
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
        const history = History.init(allocator, io, paths, config);

        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .watcher = watcher,
            .watcher_thread = null,
            .config = config,
            .loop = null,
            .current_mode = undefined,
            .history = history,
            .positions = positions,
            .doc_key = doc_key,
            .doc_abs_path = doc_abs_path,
            .paths = paths,
            .status_path = status_path,
            .outline = outline,
            // Rex keeps ~128 MiB of raw image bytes per block and silently
            // evicts the oldest beyond that (probed on build 1408).
            .cache = Cache.init(allocator, config.cache.lru_size, @as(usize, if (in_rex) @min(config.cache.budget_mb, 120) else config.cache.budget_mb) * 1024 * 1024),
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
            .grid_cell_w = restored_grid,
            .marks = marks,
            .highlights = highlights,
            .tombstones = tombstones,
            .sync = sync,
            .sync_manual = false,
            .sync_stopped = true,
            .cache_gen = .init(0),
            .view_touched = initial_page != null,
            .saved_once = false,
            .control_quit = .init(false),
            .control_thread = null,
            .presence = .{ .since = time.nowRealSeconds() },
            .last_view_ts = last_view_ts,
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
            .spread_cols = self.document_handler.spread_cols,
            .fit_width = self.document_handler.getFitWidth(),
            .crop_left = self.document_handler.crop_left,
            .crop_right = self.document_handler.crop_right,
            .crop_top = self.document_handler.crop_top,
            .crop_bottom = self.document_handler.crop_bottom,
            .grid_zoom = self.grid_cell_w,
            .touched = self.view_touched,
            .path = self.doc_abs_path,
            .last_opened = time.nowRealSeconds(),
        };
        // Most event batches change nothing persistent; skip the file
        // read-merge-write when the saved state would be identical.
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, .{
            pos.page,                            pos.scroll_x,
            pos.scroll_y,                        @as(u32, @bitCast(pos.zoom)),
            pos.odd_shift_x,                     pos.colorize,
            pos.crop,                            pos.hlock,
            pos.spread,                          pos.fit_width,
            pos.spread_cols,                     @as(u32, @bitCast(pos.crop_left)),
            @as(u32, @bitCast(pos.crop_right)),  @as(u32, @bitCast(pos.crop_top)),
            @as(u32, @bitCast(pos.crop_bottom)), pos.grid_zoom,
        });
        for (self.marks.items) |m| {
            std.hash.autoHash(&hasher, .{ m.letter, m.page, m.scroll_x, m.scroll_y });
            hasher.update(m.comment);
        }
        for (self.highlights.items) |h| {
            std.hash.autoHash(&hasher, .{ h.id, h.page, h.text.len, h.rects.len });
        }
        for (self.tombstones.items) |t| {
            std.hash.autoHash(&hasher, .{ t.kind, t.letter, t.id, t.deleted_at });
        }
        const sig = hasher.final();
        if (sig == self.last_save_sig) return;
        // The first save just persists the restored view; any later change
        // is the reader acting.
        if (self.saved_once) self.view_touched = true;
        var pos_out = pos;
        pos_out.touched = self.view_touched;
        // Only a successful write counts as saved; a failed one is retried.
        const ts = self.positions.save(pos_out, self.marks.items, self.highlights.items, self.tombstones.items) catch |err| {
            if (!self.save_warned) self.progress_text = std.fmt.bufPrint(&self.progress_buf, " state not saved: {s} ", .{@errorName(err)}) catch null;
            self.save_warned = true;
            return;
        };
        self.saved_once = true;
        self.last_save_sig = sig;
        self.last_view_ts = ts;
        self.publishPresence(pos.last_opened);
        if (self.sync) |s| s.requestPush(false);
    }

    // Polls the command inbox so an agent can move the reader (goto_page).
    fn controlWorker(self: *Self, loop: *vaxis.Loop(Event)) void {
        while (!self.control_quit.load(.acquire)) {
            if (self.positions.takeCommand(self.allocator)) |cmd| {
                loop.postEvent(.{ .control = cmd }) catch self.allocator.free(cmd);
            }
            time.sleep(200 * std.time.ns_per_ms);
        }
    }

    // `goto <page> [pdf_y]` and `select <page> <text…>` (1-based pages).
    fn handleControl(self: *Self, cmd: []const u8) void {
        var it = std.mem.tokenizeAny(u8, cmd, &std.ascii.whitespace);
        const verb = it.next() orelse return;
        const page_1 = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
        const total = self.document_handler.getTotalPages();
        if (page_1 < 1 or page_1 > total) return;
        const page: u16 = @intCast(page_1 - 1);
        if (std.mem.eql(u8, verb, "select")) {
            const text = std.mem.trim(u8, it.rest(), &std.ascii.whitespace);
            if (text.len == 0) return;
            if (Selection.selectTextOnPage(self, page, text)) {
                self.progress_text = std.fmt.bufPrint(&self.progress_buf, " agent selected on p.{d} — H to highlight, Ctrl-O to go back ", .{page_1}) catch null;
            } else {
                self.progress_text = std.fmt.bufPrint(&self.progress_buf, " agent: text not found on p.{d} ", .{page_1}) catch null;
            }
            return;
        }
        if (!std.mem.eql(u8, verb, "goto")) return;
        const y: f32 = if (it.next()) |ys| (std.fmt.parseFloat(f32, ys) catch 0) else 0;
        self.pushJump();
        if (y > 0) {
            self.gotoPagePdfY(page, y);
        } else {
            self.restorePosition(.{ .page = page, .scroll_y = 0, .scroll_x = 0 });
        }
        self.progress_text = std.fmt.bufPrint(&self.progress_buf, " agent: p.{d} (Ctrl-O to go back) ", .{page_1}) catch null;
    }

    fn syncNotify(ctx: *anyopaque, r: Sync.Result) void {
        const loop: *vaxis.Loop(Event) = @ptrCast(@alignCast(ctx));
        loop.postEvent(.{ .sync = r }) catch {};
    }

    fn onSync(self: *Self, r: Sync.Result) void {
        switch (r) {
            .pulled => |changed| {
                if (changed) {
                    self.applySynced();
                } else if (self.sync_manual) {
                    self.progress_text = " synced: up to date ";
                }
                self.sync_manual = false;
            },
            .pushed => {},
            .err => |m| {
                self.progress_text = std.fmt.bufPrint(&self.progress_buf, " sync: {s} ", .{m.text()}) catch null;
            },
        }
    }

    // Other devices' shards arrived: re-merge, take their annotations, and
    // jump to their view if it is newer than what we last saved.
    fn applySynced(self: *Self) void {
        self.positions.reload();
        self.freeAnnotations();
        self.marks = self.positions.loadMarks(self.allocator);
        self.highlights = self.positions.loadHighlights(self.allocator);
        self.tombstones = self.positions.loadTombstones(self.allocator);
        Selection.rebuildHighlightQuads(self);
        self.last_save_sig = 0;

        const pos = self.positions.getSavedPosition() orelse return;
        const foreign = !std.mem.eql(u8, pos.device, self.positions.deviceName());
        if (foreign and pos.last_opened > self.last_view_ts) {
            applyView(&self.document_handler, self.config, pos, true);
            self.lock_horizontal_scroll = pos.hlock;
            if (pos.grid_zoom >= 12 and pos.grid_zoom <= 64) self.grid_cell_w = pos.grid_zoom;
            self.last_view_ts = pos.last_opened;
            self.progress_text = std.fmt.bufPrint(&self.progress_buf, " synced: p.{d} from {s} ", .{ pos.page + 1, pos.device }) catch null;
        } else {
            self.progress_text = " synced ";
        }
        self.clearCache();
    }

    pub fn syncNow(self: *Self) void {
        if (self.sync) |s| {
            self.sync_manual = true;
            s.requestPull();
            s.requestPush(true);
            self.progress_text = if (s.allManual()) " syncing (manual backends)… " else " syncing… ";
        } else {
            self.progress_text = " sync: not configured (see docs/config.md#sync) ";
        }
    }

    fn freeAnnotations(self: *Self) void {
        for (self.marks.items) |m| {
            if (m.comment.len > 0) self.allocator.free(m.comment);
        }
        self.marks.deinit(self.allocator);
        for (self.highlights.items) |h| Selection.freeHighlight(self, h);
        self.highlights.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
    }

    pub fn deinit(self: *Self) void {
        // Before saveState: a mode's deinit may restore document state it
        // borrowed (e.g. crop mode zeroes the margins while active).
        self.deinitCurrentMode();
        if (self.pending_command_text) |t| self.allocator.free(t);
        self.saveState();
        self.freeAnnotations();
        // A worker stuck in a network call still references this; leaking it
        // at exit beats a use-after-free.
        if (self.sync) |s| if (self.sync_stopped) s.destroy();
        self.positions.clearPresence();
        self.positions.deinit();
        self.freeOutline();
        self.search_hits.deinit(self.allocator);
        if (self.search_needle.len > 0) self.allocator.free(self.search_needle);
        self.selection_hits.deinit(self.allocator);
        if (self.selection_text.len > 0) self.allocator.free(self.selection_text);
        if (self.presence.sel_text.len > 0) self.allocator.free(self.presence.sel_text);
        self.allocator.free(self.doc_key);
        self.allocator.free(self.doc_abs_path);
        self.allocator.free(self.status_path);
        self.jump_back.deinit(self.allocator);
        self.jump_forward.deinit(self.allocator);
        if (self.watcher) |*w| {
            w.stop();
            if (self.watcher_thread) |thread| thread.join();
            w.deinit();
        }

        self.reload_indicator_timer.deinit();
        self.history.deinit();
        self.paths.deinit(self.allocator);
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
        self.publishPresence(self.presence.since);

        self.prerenderer.context = self;
        if (self.config.cache.enabled) try self.prerenderer.start();
        // Declared after the loop defers so it runs first: the worker must be
        // joined while `loop` is still alive (it posts events to it).
        defer self.prerenderer.stop();
        if (self.sync) |s| s.start(syncNotify, @ptrCast(&loop)) catch {};
        self.control_thread = std.Thread.spawn(.{}, controlWorker, .{ self, &loop }) catch null;
        defer if (self.control_thread) |t| {
            self.control_quit.store(true, .release);
            t.join();
            self.control_thread = null;
        };
        // Same ordering need; the final save must land before the flush push.
        defer if (self.sync) |s| {
            if (!self.modeFlag("suppress_autosave")) self.saveState();
            self.sync_stopped = s.stop(3 * std.time.ns_per_s);
        };

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
            const evicted = self.cache.drainEvicted();
            if (evicted.len > 0) {
                for (evicted) |img| self.vx.freeImage(buffered, img.image.id);
                try buffered.flush();
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

    // Deferred to the end of the event: the switch deinits the calling mode's
    // own payload, so applying it inline would leave the caller running on
    // freed state. The last request in an event wins.
    pub fn changeMode(self: *Self, new_state: ModeType) void {
        self.next_mode = new_state;
    }

    fn applyModeChange(self: *Self) void {
        const new_state = self.next_mode orelse return;
        self.next_mode = null;
        self.deinitCurrentMode();
        switch (new_state) {
            inline else => |tag| {
                self.current_mode = @unionInit(Mode, @tagName(tag), @FieldType(Mode, @tagName(tag)).init(self));
            },
        }
        if (self.pending_command_text) |text| {
            defer self.allocator.free(text);
            self.pending_command_text = null;
            if (new_state == .command) self.current_mode.command.text_input.insertSliceAtCursor(text) catch {};
        }
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
        defer self.applyModeChange();
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
            },
            .sync => |r| self.onSync(r),
            .control => |cmd| {
                defer self.allocator.free(cmd);
                self.handleControl(cmd);
            },
            .file_changed => {
                try self.document_handler.reloadDocument();
                self.freeOutline();
                self.outline = self.document_handler.loadOutline(self.allocator) catch &.{};
                self.clearCache();
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
            .gen = self.cache_gen.load(.monotonic),
            .margins = marginsBits(&self.document_handler),
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

        const image = try self.transmitOrDiscard(encoded_image);

        const cached = Cache.CachedImage{
            .image = image,
            .origin_x = encoded_image.origin_x,
            .origin_y = encoded_image.origin_y,
        };
        if (self.config.cache.enabled) {
            // The render may have fitted the zoom (first draw, fit-width), so
            // key the entry by the zoom it was actually rendered at.
            self.cache.put(self.cacheKeyFor(page_number), cached) catch self.discardAfterFrame(cached);
        } else {
            self.discardAfterFrame(cached);
        }
        return cached;
    }

    // The image stays placed for this frame and is deleted terminal-side after it.
    pub fn discardAfterFrame(self: *Self, cached: Cache.CachedImage) void {
        self.cache.discard(cached) catch self.vx.freeImage(self.tty.writer(), cached.image.id);
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
            const img = self.transmitOrDiscard(r.image) catch continue;
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
        return self.transmitOrDiscard(enc);
    }

    // A render the terminal never reads keeps its backing file or shm object
    // unless we remove it.
    fn transmitOrDiscard(self: *Self, enc: PdfHandler.types.EncodedImage) !vaxis.Image {
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
            .shm_rgb, .png_path => return self.vx.transmitLocalImagePath(
                self.allocator,
                self.tty.writer(),
                enc.data,
                enc.width,
                enc.height,
                if (enc.kind == .shm_rgb) .shared_mem else .temp_file,
                if (enc.kind == .shm_rgb) .rgb else .png,
            ),
            .png_bytes => {
                const b64 = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(enc.data.len));
                defer self.allocator.free(b64);
                const encoded = std.base64.standard.Encoder.encode(b64, enc.data);
                return self.vx.transmitPreEncodedImage(self.tty.writer(), encoded, enc.width, enc.height, .png);
            },
        }
    }

    pub fn deleteEncoded(self: *Self, enc: PdfHandler.types.EncodedImage) void {
        PdfHandler.Exporter.delete(self.io, enc);
    }

    // Empties the render cache and queues the displaced terminal-side images
    // for deletion after the next render.
    pub fn clearCache(self: *Self) void {
        _ = self.cache_gen.fetchAdd(1, .monotonic);
        self.cache.clear() catch {};
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
            const image = self.transmitOrDiscard(r.image) catch continue;
            const cached = Cache.CachedImage{
                .image = image,
                .origin_x = r.image.origin_x,
                .origin_y = r.image.origin_y,
            };
            self.cache.put(r.key, cached) catch self.discardAfterFrame(cached);
        }
    }

    // Called after the draw walk, so every visible page is already cached;
    // `next_page` is where the walk stopped. Prefetches a render-ahead window of
    // up to ±3 pages (forward-biased, since reading is mostly forward) so fast
    // flipping stays cache-warm. Uncached targets only.
    fn requestPrerender(self: *Self, top_page: u16, next_page: u16, w: u32, h: u32) void {
        // Neighbors render at the current zoom, not refitted to the viewport.
        _ = w;
        _ = h;
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
        var jobs: [Prerenderer.slots]?Prerenderer.Job = @splat(null);
        var n: usize = 0;
        const total = self.document_handler.getTotalPages();

        // Key and render inputs are built here, on the main thread, so the
        // worker never reads view state.
        var fwd: u32 = next_page;
        while (fwd < @min(@as(u32, next_page) + window, total) and n < jobs.len) : (fwd += 1) {
            const key = self.cacheKeyFor(@intCast(fwd));
            if (self.cache.contains(key)) continue;
            const params = self.document_handler.prerenderParams(self.allocator, key.page) catch continue;
            jobs[n] = .{ .key = key, .params = params };
            n += 1;
        }
        var back: u16 = 1;
        while (back <= window and top_page >= back and n < jobs.len) : (back += 1) {
            const key = self.cacheKeyFor(top_page - back);
            if (self.cache.contains(key)) continue;
            const params = self.document_handler.prerenderParams(self.allocator, key.page) catch continue;
            jobs[n] = .{ .key = key, .params = params };
            n += 1;
        }
        if (n == 0) return;
        self.prerenderer.request(jobs);
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
        const columns: u16 = self.document_handler.getSpreadColumns();
        const col_cells: u16 = win.width / columns;
        const render_w_pix: u32 = @as(u32, col_cells) * @as(u32, pix_per_col);

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

    pub fn selectionPage(self: *Self) ?u16 {
        if (self.selection_hits.items.len == 0) return null;
        return self.selection_hits.items[0].page;
    }

    pub fn publishPresence(self: *Self, last_activity: i64) void {
        self.presence.last_activity = last_activity;
        self.positions.writePresence(self.doc_abs_path, self.presence);
    }

    // Jump to `page` scrolled so pdf_y sits near the viewport top.
    pub fn gotoPagePdfY(self: *Self, page: u16, pdf_y: f32) void {
        self.document_handler.setCurrentPage(page);
        self.document_handler.setScrollY(0);
        self.document_handler.setPendingScrollPdfY(pdf_y);
    }

    // Does not take ownership of a .uri target; the caller frees it.
    pub fn followLink(self: *Self, target: PdfHandler.LinkTarget) void {
        switch (target) {
            .page => |dest| {
                if (dest.num >= self.document_handler.getTotalPages()) return;
                self.pushJump();
                self.gotoPagePdfY(dest.num, dest.y);
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
                m.updated_at = time.nowRealSeconds();
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
            .updated_at = time.nowRealSeconds(),
        }) catch {};
    }

    pub fn jumpToMark(self: *Self, letter: u8) void {
        for (self.marks.items) |m| {
            if (m.letter == letter) {
                if (m.page < self.document_handler.getTotalPages()) {
                    self.pushJump();
                    self.restorePosition(.{ .page = m.page, .scroll_y = m.scroll_y, .scroll_x = m.scroll_x });
                }
                return;
            }
        }
    }

    pub fn deleteMark(self: *Self, letter: u8) void {
        for (self.marks.items, 0..) |m, i| {
            if (m.letter == letter) {
                self.tombstones.append(self.allocator, .{ .kind = .mark, .letter = letter, .deleted_at = time.nowRealSeconds() }) catch {};
                if (m.comment.len > 0) self.allocator.free(m.comment);
                _ = self.marks.orderedRemove(i);
                return;
            }
        }
    }

    pub fn freeOutline(self: *Self) void {
        for (self.outline) |e| self.allocator.free(e.title);
        if (self.outline.len > 0) self.allocator.free(self.outline);
        self.outline = &.{};
    }

    pub fn flashProgress(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.progress_buf, fmt, args) catch return;
        self.progress_text = msg;
        const win = self.vx.window();
        // This renders mid-update without a full repaint, so every screen cell
        // it leaves in place must still reference live memory. Callers that
        // freed text backing on-screen cells (e.g. TextInput's toOwnedSlice)
        // must repaint those cells before triggering a flash.
        StatusBar.drawStatusBar(self, win) catch return;
        var w = self.tty.writer();
        self.vx.render(w) catch return;
        w.flush() catch return;
    }

    pub fn enterCommandWithText(self: *Self, text: []const u8) void {
        if (self.pending_command_text) |old| self.allocator.free(old);
        self.pending_command_text = self.allocator.dupe(u8, text) catch null;
        self.changeMode(.command);
    }

    pub fn setMarkComment(self: *Self, letter: u8, comment: []const u8) !void {
        for (self.marks.items) |*m| {
            if (m.letter == letter) {
                if (m.comment.len > 0) self.allocator.free(m.comment);
                m.comment = try self.allocator.dupe(u8, comment);
                m.updated_at = time.nowRealSeconds();
                return;
            }
        }
    }

    pub fn runSearch(self: *Self, needle: []const u8) !void {
        self.clearSearch();
        if (needle.len == 0) return;
        self.search_needle = try self.allocator.dupe(u8, needle);
        const needle_z = try self.allocator.dupeSentinel(u8, needle, 0);
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
    }

    pub fn gotoHit(self: *Self, index: usize) void {
        const h = self.search_hits.items[index];
        self.pushJump();
        self.gotoPagePdfY(h.page, h.y0);
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

    pub fn draw(self: *Self) !void {
        _ = self.arena.reset(.retain_capacity);
        const win = self.vx.window();
        win.clear();

        try self.drawCurrentPage(win);

        if (self.current_mode == .command) {
            self.current_mode.command.drawCommandBar(win);
        } else if (self.current_mode == .search) {
            self.current_mode.search.drawSearchBar(win);
        } else if (self.config.status_bar.enabled) {
            try StatusBar.drawStatusBar(self, win);
        }
        switch (self.current_mode) {
            inline else => |*m| {
                if (comptime @hasDecl(@TypeOf(m.*), "draw")) m.draw(win);
            },
        }
    }

    // Scratch memory for one frame; reset at the top of draw().
    pub fn frameAlloc(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    // Reads a mode's comptime trait flag (e.g. `pub const hides_page = true;`)
    // so modes declare their behavior instead of Context keeping per-mode lists.
    fn modeFlag(self: *Self, comptime flag: []const u8) bool {
        return switch (self.current_mode) {
            inline else => |*m| comptime if (@hasDecl(@TypeOf(m.*), flag)) @field(@TypeOf(m.*), flag) else false,
        };
    }
};

// Puts saved view state onto the document: at open, and when a sync pulls a
// newer view from another device.
fn applyView(dh: *PdfHandler, config: *Config, pos: Positions.Position, apply_position: bool) void {
    config.general.colorize = pos.colorize;
    // Crop/spread first: their toggles reset zoom/scroll, so they must run
    // before the restored values or they wipe them.
    if (pos.crop != dh.getCropToContent()) dh.toggleCropToContent();
    if (pos.spread) {
        dh.setSpreadColumns(pos.spread_cols);
    } else if (dh.getSpread()) dh.toggleSpread();
    if (pos.crop_left != dh.crop_left or pos.crop_right != dh.crop_right or pos.crop_top != dh.crop_top or pos.crop_bottom != dh.crop_bottom) {
        dh.setMarginCrop(pos.crop_left, pos.crop_right, pos.crop_top, pos.crop_bottom);
    }
    if (apply_position and pos.page < dh.getTotalPages()) {
        dh.setCurrentPage(pos.page);
        dh.setScrollX(pos.scroll_x);
        dh.setScrollY(pos.scroll_y);
    }
    if (pos.zoom > 0) dh.setActiveZoom(pos.zoom);
    dh.setOddShiftX(pos.odd_shift_x);
    // Last: when locked to fit-width, the zoom is recomputed at render.
    if (pos.fit_width != dh.getFitWidth()) dh.setFitWidth(pos.fit_width);
}

fn makeSync(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config, positions: *Positions) ?*Sync {
    if (positions.booksDir().len == 0) return null;
    const backends = Sync.backendsFromConfig(allocator, io, env, config);
    if (backends.len == 0) return null;
    return Sync.create(allocator, io, backends, positions.booksDir(), positions.bookName(), positions.deviceName()) catch null;
}

fn marginsBits(dh: *PdfHandler) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHash(&h, .{ @as(u32, @bitCast(dh.crop_left)), @as(u32, @bitCast(dh.crop_right)), @as(u32, @bitCast(dh.crop_top)), @as(u32, @bitCast(dh.crop_bottom)) });
    return h.final();
}
