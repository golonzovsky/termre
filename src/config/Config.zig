const Self = @This();
const std = @import("std");
const fs = @import("../utilities/fs.zig");
const meta = @import("../utilities/meta.zig");
const yaml = @import("yaml");
const vaxis = @import("vaxis");

pub const KeyMap = struct {
    next: vaxis.Key = .{ .codepoint = 'n' },
    prev: vaxis.Key = .{ .codepoint = 'p' },
    scroll_up: vaxis.Key = .{ .codepoint = 'k' },
    scroll_down: vaxis.Key = .{ .codepoint = 'j' },
    scroll_left: vaxis.Key = .{ .codepoint = 'h' },
    scroll_right: vaxis.Key = .{ .codepoint = 'l' },
    scroll_half_down: vaxis.Key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } },
    scroll_half_up: vaxis.Key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
    zoom_in: vaxis.Key = .{ .codepoint = 'i' },
    zoom_out: vaxis.Key = .{ .codepoint = 'o' },
    width_mode: vaxis.Key = .{ .codepoint = 'w' },
    fit_width: vaxis.Key = .{ .codepoint = 'W' },
    crop_to_content: vaxis.Key = .{ .codepoint = 't' },
    crop_mode: vaxis.Key = .{ .codepoint = 'c' },
    toggle_spread: vaxis.Key = .{ .codepoint = 'd' },
    hint_mode: vaxis.Key = .{ .codepoint = ';' },
    set_mark: vaxis.Key = .{ .codepoint = 'm' },
    jump_mark: vaxis.Key = .{ .codepoint = '\'' },
    toc_mode: vaxis.Key = .{ .codepoint = 'T' },
    marks_mode: vaxis.Key = .{ .codepoint = 'M' },
    grid_mode: vaxis.Key = .{ .codepoint = 'g' },
    library_mode: vaxis.Key = .{ .codepoint = 'b' },
    colorize: vaxis.Key = .{ .codepoint = 'z' },
    quit: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } },
    full_screen: vaxis.Key = .{ .codepoint = 'f' },
    enter_command_mode: vaxis.Key = .{ .codepoint = ':' },
    exit_command_mode: vaxis.Key = .{ .codepoint = vaxis.Key.escape },
    execute_command: vaxis.Key = .{ .codepoint = vaxis.Key.enter },
    complete_command: vaxis.Key = .{ .codepoint = vaxis.Key.tab },
    history_back: vaxis.Key = .{ .codepoint = vaxis.Key.up },
    history_forward: vaxis.Key = .{ .codepoint = vaxis.Key.down },
    jump_back: vaxis.Key = .{ .codepoint = 'o', .mods = .{ .ctrl = true } },
    jump_forward: vaxis.Key = .{ .codepoint = vaxis.Key.tab },
    open_in_editor: vaxis.Key = .{ .codepoint = 'e' },
    open_chapter_in_editor: vaxis.Key = .{ .codepoint = 'E' },
    show_help: vaxis.Key = .{ .codepoint = '?' },
    search: vaxis.Key = .{ .codepoint = '/' },
    search_next: vaxis.Key = .{ .codepoint = 'N' },
    search_prev: vaxis.Key = .{ .codepoint = 'P' },
    search_list: vaxis.Key = .{ .codepoint = 'S' },
    add_highlight: vaxis.Key = .{ .codepoint = 'H' },
    highlights_mode: vaxis.Key = .{ .codepoint = 'V' },
    list_top: vaxis.Key = .{ .codepoint = 'g' },
    list_bottom: vaxis.Key = .{ .codepoint = 'G' },
    list_select: vaxis.Key = .{ .codepoint = vaxis.Key.enter },
    list_delete: vaxis.Key = .{ .codepoint = 'd' },
    list_edit: vaxis.Key = .{ .codepoint = 'r' },

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) KeyMap {
        return parseFields(KeyMap, val, allocator);
    }

    pub fn parseField(comptime name: []const u8, obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback: vaxis.Key) vaxis.Key {
        return parseKeyBinding(obj, name, allocator, fallback);
    }
};

pub const FileMonitor = struct {
    enabled: bool = true,
    // Amount of time in seconds to wait in between polling for file changes
    latency: f16 = 0.1,
    reload_indicator_duration: f16 = 1.0,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) FileMonitor {
        return parseFields(FileMonitor, val, allocator);
    }
};

pub const General = struct {
    colorize: bool = false,
    white: i32 = 0x000000,
    black: i32 = 0xffffff,
    // size of the pdf
    // 1 is the whole window
    size: f32 = 1.0,
    // multiplicative per i/o keystroke; 1.1 = 10% step. Override in config for coarser.
    zoom_step: f32 = 1.1,
    zoom_min: f32 = 1.0,
    // pixels
    scroll_step: f32 = 100.0,
    // seconds
    retry_delay: f32 = 0.2,
    timeout: f32 = 5.0,
    // resolution
    detect_dpi: bool = true,
    // Raw-RGB shared-memory image transfer (kitty t=s); disable for terminals
    // without shm support to fall back to PNG temp files.
    shm_transfer: bool = true,
    dpi: f32 = 96.0,
    // whole number (possibly 0)
    history: u32 = 1000,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) General {
        return parseFields(General, val, allocator);
    }

    // white/black accept hex-string or {rgb} forms, not plain integers.
    pub fn parseField(comptime name: []const u8, obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback: anytype) @TypeOf(fallback) {
        if (comptime std.mem.eql(u8, name, "white") or std.mem.eql(u8, name, "black")) {
            const raw = obj.get(name) orelse return fallback;
            return if (parseRGB(raw, allocator)) |rgb| rgbToInt(rgb) else fallback;
        }
        return parseType(@TypeOf(fallback), obj, name, allocator, fallback);
    }
};

pub const StatusBar = struct {
    pub const StyledItem = struct {
        text: []const u8,
        style: vaxis.Cell.Style,
    };
    pub const ModeAwareItem = struct {
        view: StyledItem,
        command: StyledItem,
    };
    pub const ReloadAwareItem = struct {
        idle: StyledItem,
        reload: StyledItem,
        watching: StyledItem,
    };
    pub const Item = union(enum) {
        styled: StyledItem,
        mode_aware: ModeAwareItem,
        reload_aware: ReloadAwareItem,
    };

    const default_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 0, 0, 0 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
    };

    pub const PATH = "<path>";
    pub const SEPARATOR = "<separator>";
    pub const PAGE = "<page>";
    pub const TOTAL_PAGES = "<total_pages>";
    pub const HLOCK = "<hlock>";
    pub const FIT = "<fit>";
    pub const ODDX = "<oddx>";
    pub const CROP = "<crop>";
    pub const CHAPTER = "<chapter>";
    pub const PERCENT = "<percent>";
    pub const SEARCH = "<search>";

    pub const default_items: []const StatusBar.Item = &.{
        .{ .styled = .{ .text = " ", .style = default_style } },
        .{ .mode_aware = .{
            .view = .{ .text = "VIS", .style = default_style },
            .command = .{ .text = "CMD", .style = default_style },
        } },
        .{ .styled = .{ .text = "   ", .style = default_style } },
        .{ .styled = .{ .text = PATH, .style = default_style } },
        .{ .styled = .{ .text = " ", .style = default_style } },
        .{ .reload_aware = .{
            .idle = .{ .text = " ", .style = default_style },
            .reload = .{ .text = "*", .style = default_style },
            .watching = .{ .text = " ", .style = default_style },
        } },
        .{ .styled = .{ .text = " ", .style = default_style } },
        .{ .styled = .{ .text = CHAPTER, .style = default_style } },
        .{ .styled = .{ .text = SEPARATOR, .style = default_style } },
        .{ .styled = .{ .text = SEARCH, .style = default_style } },
        .{ .styled = .{ .text = CROP, .style = default_style } },
        .{ .styled = .{ .text = ODDX, .style = default_style } },
        .{ .styled = .{ .text = FIT, .style = default_style } },
        .{ .styled = .{ .text = HLOCK, .style = default_style } },
        .{ .styled = .{ .text = PAGE, .style = default_style } },
        .{ .styled = .{ .text = ":", .style = default_style } },
        .{ .styled = .{ .text = TOTAL_PAGES, .style = default_style } },
        .{ .styled = .{ .text = " · ", .style = default_style } },
        .{ .styled = .{ .text = PERCENT, .style = default_style } },
        .{ .styled = .{ .text = "% ", .style = default_style } },
    };

    enabled: bool = true,
    style: vaxis.Cell.Style = default_style,
    items: []const StatusBar.Item = default_items,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) StatusBar {
        var status_bar = StatusBar{};
        if (val != .object) return status_bar;

        status_bar.enabled = parseType(bool, val.object, "enabled", allocator, status_bar.enabled);
        status_bar.style = parseStyle(val.object, allocator, status_bar.style);
        status_bar.items = parseItems(val.object, allocator, status_bar.style);

        return status_bar;
    }
};

pub const Cache = struct {
    enabled: bool = true,
    // Number of rendered pages kept resident (also terminal-side images). Sized
    // to hold the ±3 render-ahead window plus the visible pages without churn.
    lru_size: u16 = 14,
    // Upper bound on decoded image bytes kept alive in the terminal; stays
    // under typical terminal image-storage quotas (~320MB) so the terminal
    // never silently evicts the visible page.
    budget_mb: u16 = 200,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) Cache {
        return parseFields(Cache, val, allocator);
    }
};

// One sync backend. Several can be active at once; each has its own mode.
pub const SyncEntry = struct {
    // "dir" | "s3" | "git"
    type: []const u8 = "",
    // "manual": only `:sync` / `re state sync`. "open-close": pull at open,
    // push at quit. "periodic": open-close plus debounced pushes while
    // reading. Default: manual for git, periodic otherwise.
    mode: []const u8 = "",
    enabled: bool = true,
    // Time between automatic pushes: "10s", "5m", "3h", "1d". Empty =
    // default (10s; 3h for git).
    debounce: []const u8 = "",
    // dir
    path: []const u8 = "",
    // s3 (empty keys -> AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
    bucket: []const u8 = "",
    region: []const u8 = "",
    endpoint: []const u8 = "",
    prefix: []const u8 = "termre",
    access_key: []const u8 = "",
    secret_key: []const u8 = "",
    // git: a folder inside a repo (created if missing), or cloned from `remote`
    dir: []const u8 = "",
    remote: []const u8 = "",

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) SyncEntry {
        return parseFields(SyncEntry, val, allocator);
    }
};

fn parseSync(val: std.json.Value, allocator: std.mem.Allocator) []const SyncEntry {
    switch (val) {
        .array => |arr| {
            var list: std.ArrayList(SyncEntry) = .empty;
            for (arr.items) |item| {
                if (item != .object) continue;
                list.append(allocator, SyncEntry.parse(item, allocator)) catch break;
            }
            return list.toOwnedSlice(allocator) catch &.{};
        },
        else => return &.{},
    }
}

// Written on first run so the file explains itself.
const template =
    \\# termre — https://github.com/golonzovsky/termre/blob/master/docs/config.md
    \\# Every key is optional; these are the defaults.
    \\
    \\# Reading state (position, marks, highlights per book + device) and the
    \\# device name live here. Default: $XDG_STATE_HOME/termre or ~/.local/state/termre
    \\# stateDir: ~/.local/state/termre
    \\# PDFs opened by URL (`re https://arxiv.org/abs/…`) are saved here.
    \\# downloadDir: ~/.local/state/termre/downloads
    \\
    \\# Sync backends; any number, each with its own mode.
    \\# sync:
    \\#   - type: s3                  # AWS S3, Cloudflare R2, Backblaze B2, MinIO
    \\#     mode: periodic            # pull at open, push while reading and on quit
    \\#     bucket: my-books
    \\#     region: auto
    \\#     endpoint: <account>.r2.cloudflarestorage.com
    \\#     accessKey: ""             # empty: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
    \\#     secretKey: ""
    \\#   - type: git                 # a folder in a repo (dotfiles) or a dedicated clone
    \\#     mode: manual              # only :sync / re state sync
    \\#     dir: ~/.local/state/termre/git
    \\#     remote: git@github.com:you/termre-state.git
    \\#   - type: dir                 # any synced folder (Syncthing, iCloud Drive, rsync)
    \\#     path: ~/Sync/termre
    \\
    \\# general:
    \\#   colorize: false
    \\#   zoomStep: 1.1
    \\
;

arena: std.heap.ArenaAllocator,

// Where reading state lives; empty = $XDG_STATE_HOME/termre or ~/.local/state/termre.
state_dir: []const u8 = "",
// Where `re <url>` saves PDFs; empty = <stateDir>/downloads.
download_dir: []const u8 = "",

key_map: KeyMap = .{},
file_monitor: FileMonitor = .{},
general: General = .{},
status_bar: StatusBar = .{},
cache: Cache = .{},
sync: []const SyncEntry = &.{},
// Why the file, or a part of it, was ignored; empty when it loaded clean.
problem: []const u8 = "",

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) Self {
    var self = Self{ .arena = std.heap.ArenaAllocator.init(allocator) };

    const home = env.get("HOME") orelse return self;

    const dir = if (env.get("XDG_CONFIG_HOME")) |x|
        std.fmt.allocPrint(allocator, "{s}/termre", .{x}) catch return self
    else
        std.fmt.allocPrint(allocator, "{s}/.config/termre", .{home}) catch return self;
    defer allocator.free(dir);
    const cwd = std.Io.Dir.cwd();
    const cfg_path = std.fmt.allocPrint(allocator, "{s}/config.yaml", .{dir}) catch return self;
    defer allocator.free(cfg_path);
    const content = cwd.readFileAlloc(io, cfg_path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            fs.writeFileAtomic(io, cfg_path, template) catch {};
        } else {
            self.problem = std.fmt.allocPrint(self.arena.allocator(), "config.yaml unreadable ({s}): using defaults", .{@errorName(err)}) catch "";
        }
        return self;
    };
    defer allocator.free(content);
    self.load(content);
    return self;
}

fn load(self: *Self, content: []const u8) void {
    const arena_allocator = self.arena.allocator();
    if (content.len == 0) return;

    if (unclosedQuoteLine(content)) |line| {
        self.problem = std.fmt.allocPrint(arena_allocator, "config.yaml line {d}: quote is never closed: using defaults", .{line}) catch "config.yaml: a quote is never closed: using defaults";
        return;
    }
    var root: std.json.Value = parseYaml(arena_allocator, content, &self.problem) catch |err| {
        if (self.problem.len == 0) self.problem = std.fmt.allocPrint(arena_allocator, "config.yaml: {s}: using defaults", .{@errorName(err)}) catch "config.yaml is not valid YAML: using defaults";
        return;
    };
    if (root == .null) return;
    if (root != .object) {
        self.problem = "config.yaml: the top level must be a map: using defaults";
        return;
    }
    for (root.object.keys()) |key| {
        if (isSection(toSnake(arena_allocator, key) catch continue)) continue;
        self.problem = std.fmt.allocPrint(arena_allocator, "config.yaml: `{s}` is not a top-level key (indentation?): ignored", .{key}) catch "";
        break;
    }
    normalizeKeys(arena_allocator, &root.object) catch return;

    if (root.object.get("key_map")) |key_map| self.key_map = KeyMap.parse(key_map, arena_allocator);
    if (root.object.get("file_monitor")) |file_monitor| self.file_monitor = FileMonitor.parse(file_monitor, arena_allocator);
    if (root.object.get("general")) |general| self.general = General.parse(general, arena_allocator);
    if (root.object.get("status_bar")) |status_bar| self.status_bar = StatusBar.parse(status_bar, arena_allocator);
    if (root.object.get("cache")) |cache| self.cache = Cache.parse(cache, arena_allocator);
    if (root.object.get("sync")) |sync| self.sync = parseSync(sync, arena_allocator);
    if (root.object.get("download_dir")) |dd| {
        if (dd == .string) self.download_dir = arena_allocator.dupe(u8, dd.string) catch "";
    }
    if (root.object.get("state_dir")) |sd| {
        if (sd == .string) self.state_dir = arena_allocator.dupe(u8, sd.string) catch "";
    }
}

fn isSection(key: []const u8) bool {
    inline for (.{ "key_map", "file_monitor", "general", "status_bar", "cache", "sync", "download_dir", "state_dir" }) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn parseKeyBinding(obj: std.json.ObjectMap, name: []const u8, allocator: std.mem.Allocator, fallback: vaxis.Key) vaxis.Key {
    const val = obj.get(name) orelse return fallback;
    if (val != .object) return fallback;

    const key_str = parseType([]const u8, val.object, "key", allocator, "");
    if (key_str.len == 0) return fallback;

    var binding = fallback;
    const key_name = if (key_str.len > 1) toSnake(allocator, key_str) catch key_str else key_str;
    binding.codepoint = vaxis.Key.name_map.get(key_name) orelse cp: {
        const view = std.unicode.Utf8View.init(key_str) catch return fallback;
        var it = view.iterator();
        const first = it.nextCodepoint() orelse return fallback;
        if (it.nextCodepoint() != null) return fallback;
        break :cp first;
    };

    var mods = vaxis.Key.Modifiers{};
    binding.mods = mods;
    const modifiers = val.object.get("modifiers") orelse return binding;
    if (modifiers != .array) return binding;

    for (modifiers.array.items) |mod| {
        if (mod != .string) continue;
        const mod_name = toSnake(allocator, mod.string) catch mod.string;
        inline for (comptime meta.fields(vaxis.Key.Modifiers)) |f| {
            if (f.type == bool and std.mem.eql(u8, mod_name, f.name)) @field(mods, f.name) = true;
        }
    }

    binding.mods = mods;

    return binding;
}

fn parseType(comptime T: type, obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator, fallback: T) T {
    if (obj.get(key)) |raw_key| {
        return std.json.innerParseFromValue(T, allocator, raw_key, .{}) catch fallback;
    }
    return fallback;
}

// zig-yaml (e5cf8ac) folds a trailing `# comment` into the value before it;
// drop such comments (outside quotes) before parsing.
fn stripTrailingComments(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(arena, std.mem.trimEnd(u8, line[0..scanLine(line).cut], " \t"));
        try out.append(arena, '\n');
    }
    return out.items;
}

// zig-yaml drops everything after a quote that never closes, without an error.
fn unclosedQuoteLine(source: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (scanLine(line).open_quote) return line_no;
    }
    return null;
}

// A quote opens a scalar only where a value can start; `don't` is plain text.
fn scanLine(line: []const u8) struct { cut: usize, open_quote: bool } {
    var quote: u8 = 0;
    var before: u8 = ':';
    for (line, 0..) |ch, i| {
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if ((ch == '"' or ch == '\'') and std.mem.indexOfScalar(u8, ":-[{,", before) != null) {
            quote = ch;
        } else if (ch == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return .{ .cut = i, .open_quote = false };
        }
        if (ch != ' ' and ch != '\t') before = ch;
    }
    return .{ .cut = line.len, .open_quote = quote != 0 };
}

// zig-yaml gives scalars as text. Numbers stay strings: the typed parse reads
// them, and a string field keeps a numeric-looking value (`bucket: 2024`).
fn parseYaml(arena: std.mem.Allocator, raw: []const u8, problem: *[]const u8) !std.json.Value {
    const source = try stripTrailingComments(arena, raw);
    var y = yaml.Yaml{ .source = source };
    defer y.deinit(arena);
    y.load(arena) catch |err| {
        const eb = y.parse_errors;
        if (err == error.ParseFailure and eb.errorMessageCount() > 0) {
            const msg = eb.getErrorMessage(eb.getMessages()[0]);
            const full = eb.nullTerminatedString(msg.msg);
            const text = full[0 .. std.mem.indexOf(u8, full, ": .{") orelse full.len];
            problem.* = if (msg.src_loc == .none)
                try std.fmt.allocPrint(arena, "config.yaml: {s}: using defaults", .{text})
            else
                try std.fmt.allocPrint(arena, "config.yaml line {d}: {s}: using defaults", .{ eb.getSourceLocation(msg.src_loc).line + 1, text });
        }
        return err;
    };
    if (y.docs.items.len == 0) return .null;
    return yamlToJson(arena, y.docs.items[0]);
}

fn yamlToJson(arena: std.mem.Allocator, v: yaml.Yaml.Value) !std.json.Value {
    switch (v) {
        .empty => return .null,
        .boolean => |b| return .{ .bool = b },
        .scalar => |s| {
            if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~")) return .null;
            if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, s, "false")) return .{ .bool = false };
            return .{ .string = try arena.dupe(u8, s) };
        },
        .list => |items| {
            var arr = std.json.Array.init(arena);
            for (items) |item| try arr.append(try yamlToJson(arena, item));
            return .{ .array = arr };
        },
        .map => |map| {
            var obj = std.json.ObjectMap.empty;
            var it = map.iterator();
            while (it.next()) |kv| try obj.put(arena, try arena.dupe(u8, kv.key_ptr.*), try yamlToJson(arena, kv.value_ptr.*));
            return .{ .object = obj };
        },
    }
}

// Config keys are lowerCamelCase (`statusBar`, `zoomStep`); struct fields
// are snake_case. Rewrite every object key once, recursively.
fn normalizeKeys(arena: std.mem.Allocator, obj: *std.json.ObjectMap) !void {
    var renamed = std.json.ObjectMap.empty;
    var it = obj.iterator();
    while (it.next()) |kv| {
        var v = kv.value_ptr.*;
        switch (v) {
            .object => |*o| try normalizeKeys(arena, o),
            .array => |arr| for (arr.items) |*item| {
                if (item.* == .object) try normalizeKeys(arena, &item.object);
            },
            else => {},
        }
        try renamed.put(arena, try toSnake(arena, kv.key_ptr.*), v);
    }
    obj.* = renamed;
}

fn toSnake(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key, 0..) |ch, i| {
        if (std.ascii.isUpper(ch)) {
            if (i > 0) try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(ch));
        } else try out.append(arena, ch);
    }
    return out.toOwnedSlice(arena);
}

// Fills every field of T from the JSON object, keeping the default on miss/mismatch.
// A `parseField(name, obj, allocator, fallback)` decl on T takes over per field.
fn parseFields(comptime T: type, val: std.json.Value, allocator: std.mem.Allocator) T {
    var result = T{};
    if (val != .object) return result;
    inline for (comptime meta.fields(T)) |f| {
        const fallback = @field(result, f.name);
        @field(result, f.name) = if (@hasDecl(T, "parseField"))
            T.parseField(f.name, val.object, allocator, fallback)
        else
            parseType(f.type, val.object, f.name, allocator, fallback);
    }
    return result;
}

fn rgbToInt(rgb: [3]u8) i32 {
    return @intCast((@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]));
}

fn parseStyle(obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback: vaxis.Cell.Style) vaxis.Cell.Style {
    const val = obj.get("style") orelse return fallback;
    if (val != .object) return fallback;

    var style = fallback;
    inline for (comptime meta.fields(vaxis.Cell.Style)) |field| {
        if (val.object.get(field.name)) |field_val| {
            if (comptime std.mem.eql(u8, field.name, "fg") or std.mem.eql(u8, field.name, "bg") or std.mem.eql(u8, field.name, "ul")) {
                if (parseRGB(field_val, allocator)) |rgb| {
                    @field(style, field.name) = .{ .rgb = rgb };
                } else {
                    @field(style, field.name) = std.json.innerParseFromValue(field.type, allocator, field_val, .{}) catch @field(style, field.name);
                }
            } else {
                @field(style, field.name) = std.json.innerParseFromValue(field.type, allocator, field_val, .{}) catch @field(style, field.name);
            }
        }
    }

    return style;
}

fn parseRGB(val: std.json.Value, allocator: std.mem.Allocator) ?[3]u8 {
    switch (val) {
        .string => |str| {
            var hex = str;
            if (hex.len == 0) return null;
            if (std.mem.startsWith(u8, hex, "#")) hex = hex[1..];
            if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
            if (hex.len != 6) return null;

            const rgb_int = std.fmt.parseInt(u32, hex, 16) catch return null;
            const r = @as(u8, @intCast((rgb_int >> 16) & 0xFF));
            const g = @as(u8, @intCast((rgb_int >> 8) & 0xFF));
            const b = @as(u8, @intCast(rgb_int & 0xFF));
            return .{ r, g, b };
        },
        .object => |obj| {
            const rgb_val = obj.get("rgb") orelse return null;
            const rgb = std.json.innerParseFromValue([3]u8, allocator, rgb_val, .{}) catch return null;
            return rgb;
        },
        else => return null,
    }
}

fn parseItems(obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback_style: vaxis.Cell.Style) []const StatusBar.Item {
    const raw_items = obj.get("items") orelse {
        const items = allocator.alloc(StatusBar.Item, StatusBar.default_items.len) catch return StatusBar.default_items;
        for (StatusBar.default_items, 0..) |item, i| {
            items[i] = applyStyle(item, fallback_style, allocator);
        }
        return items;
    };

    if (raw_items != .array) return StatusBar.default_items;

    const items = allocator.alloc(StatusBar.Item, raw_items.array.items.len) catch return StatusBar.default_items;
    for (raw_items.array.items, 0..) |item, i| {
        items[i] = parseItem(item, allocator, fallback_style);
    }
    return items;
}

fn applyStyle(item: StatusBar.Item, style: vaxis.Cell.Style, allocator: std.mem.Allocator) StatusBar.Item {
    const dupe = struct {
        fn f(a: std.mem.Allocator, text: []const u8, s: vaxis.Cell.Style) StatusBar.StyledItem {
            return .{ .text = a.dupe(u8, text) catch "", .style = s };
        }
    }.f;

    return switch (item) {
        .styled => |styled| .{ .styled = dupe(allocator, styled.text, style) },
        .mode_aware => |mode_aware| .{ .mode_aware = .{
            .view = dupe(allocator, mode_aware.view.text, style),
            .command = dupe(allocator, mode_aware.command.text, style),
        } },
        .reload_aware => |reload_aware| .{ .reload_aware = .{
            .idle = dupe(allocator, reload_aware.idle.text, style),
            .reload = dupe(allocator, reload_aware.reload.text, style),
            .watching = dupe(allocator, reload_aware.watching.text, style),
        } },
    };
}

fn parseItem(val: std.json.Value, allocator: std.mem.Allocator, fallback_style: vaxis.Cell.Style) StatusBar.Item {
    const empty = StatusBar.StyledItem{ .text = "", .style = fallback_style };

    switch (val) {
        .string => |str| return .{ .styled = .{ .text = allocator.dupe(u8, str) catch "", .style = fallback_style } },

        .object => |obj| {
            if (obj.contains("view") or obj.contains("command")) {
                return .{ .mode_aware = .{
                    .view = parseStyledItem(obj.get("view"), allocator, empty),
                    .command = parseStyledItem(obj.get("command"), allocator, empty),
                } };
            }
            if (obj.contains("idle") or obj.contains("reload") or obj.contains("watching")) {
                return .{ .reload_aware = .{
                    .idle = parseStyledItem(obj.get("idle"), allocator, empty),
                    .reload = parseStyledItem(obj.get("reload"), allocator, empty),
                    .watching = parseStyledItem(obj.get("watching"), allocator, empty),
                } };
            }
            return .{ .styled = parseStyledItem(val, allocator, empty) };
        },

        else => return .{ .styled = empty },
    }
}

fn parseStyledItem(val: ?std.json.Value, allocator: std.mem.Allocator, fallback: StatusBar.StyledItem) StatusBar.StyledItem {
    const item = val orelse return fallback;

    var styled_item = fallback;
    switch (item) {
        .string => |str| {
            styled_item.text = allocator.dupe(u8, str) catch fallback.text;
            return styled_item;
        },
        .object => |obj| {
            if (obj.get("text")) |raw_text| {
                const text = std.json.innerParseFromValue([]const u8, allocator, raw_text, .{}) catch return styled_item;
                styled_item.text = allocator.dupe(u8, text) catch fallback.text;
            } else {
                styled_item.text = fallback.text;
            }
            if (obj.get("style")) |raw_style| {
                if (raw_style == .object)
                    styled_item.style = parseStyle(obj, allocator, fallback.style);
            }

            return styled_item;
        },
        else => return styled_item,
    }
}

fn loadForTest(content: []const u8) Self {
    var self = Self{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    self.load(content);
    return self;
}

test "keyMap: documented key names, digits, UTF-8 keys and modifiers" {
    const testing = std.testing;
    var cfg = loadForTest(
        \\keyMap:
        \\  next:
        \\    key: pageDown
        \\  prev:
        \\    key: 1
        \\  zoomIn:
        \\    key: é
        \\  zoomOut:
        \\    key: x
        \\    modifiers: [ctrl, capsLock]
        \\  quit:
        \\    key: escape
        \\
    );
    defer cfg.deinit();
    try testing.expectEqual(vaxis.Key.page_down, cfg.key_map.next.codepoint);
    try testing.expectEqual(@as(u21, '1'), cfg.key_map.prev.codepoint);
    try testing.expectEqual(@as(u21, 0xe9), cfg.key_map.zoom_in.codepoint);
    try testing.expectEqual(@as(u21, 'x'), cfg.key_map.zoom_out.codepoint);
    try testing.expect(cfg.key_map.zoom_out.mods.ctrl and cfg.key_map.zoom_out.mods.caps_lock);
    try testing.expectEqual(vaxis.Key.escape, cfg.key_map.quit.codepoint);
    try testing.expect(!cfg.key_map.quit.mods.ctrl);
    try testing.expectEqual(@as(u21, 'k'), cfg.key_map.scroll_up.codepoint);
}

test "general, cache and sync sections parse with typed values" {
    const testing = std.testing;
    var cfg = loadForTest(
        \\stateDir: ~/state   # trailing comment
        \\general:
        \\  colorize: true
        \\  zoomStep: 1.25
        \\  white: "#102030"
        \\  black:
        \\    rgb: [16, 32, 48]
        \\  history: 50
        \\cache:
        \\  lruSize: 6
        \\sync:
        \\  - type: s3
        \\    bucket: 2024
        \\    enabled: false
        \\  - type: dir
        \\    path: ~/Sync/termre
        \\
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("~/state", cfg.state_dir);
    try testing.expect(cfg.general.colorize);
    try testing.expectEqual(@as(f32, 1.25), cfg.general.zoom_step);
    try testing.expectEqual(@as(i32, 0x102030), cfg.general.white);
    try testing.expectEqual(@as(i32, 0x102030), cfg.general.black);
    try testing.expectEqual(@as(u32, 50), cfg.general.history);
    try testing.expectEqual(@as(u16, 6), cfg.cache.lru_size);
    try testing.expectEqual(@as(usize, 2), cfg.sync.len);
    try testing.expectEqualStrings("2024", cfg.sync[0].bucket);
    try testing.expect(!cfg.sync[0].enabled);
    try testing.expectEqualStrings("~/Sync/termre", cfg.sync[1].path);
}

test "a config that cannot be used says why" {
    const testing = std.testing;
    var clean = loadForTest("# only comments\n");
    defer clean.deinit();
    try testing.expectEqualStrings("", clean.problem);

    var template_cfg = loadForTest(template);
    defer template_cfg.deinit();
    try testing.expectEqualStrings("", template_cfg.problem);

    var broken = loadForTest(
        \\general:
        \\  colorize: true
        \\ zoomStep: 1.25
        \\
    );
    defer broken.deinit();
    try testing.expectEqualStrings("config.yaml: `zoomStep` is not a top-level key (indentation?): ignored", broken.problem);
    try testing.expect(broken.general.colorize);

    var no_colon = loadForTest("general:\n  colorize: true\n  zoomStep 1.25\n");
    defer no_colon.deinit();
    try testing.expectEqualStrings("config.yaml line 3: expected map separator ':': using defaults", no_colon.problem);
    try testing.expect(!no_colon.general.colorize);

    var open_quote = loadForTest("general:\n  white: \"#102030\ncache:\n  lruSize: 6\n");
    defer open_quote.deinit();
    try testing.expectEqualStrings("config.yaml line 2: quote is never closed: using defaults", open_quote.problem);

    var apostrophe = loadForTest("general:\n  colorize: true # don't\ncache:\n  lruSize: 6 # it's\n");
    defer apostrophe.deinit();
    try testing.expectEqualStrings("", apostrophe.problem);
    try testing.expectEqual(@as(u16, 6), apostrophe.cache.lru_size);

    // This used to index past the token list in the parser.
    var empty_value = loadForTest("general:\n  colorize: true\n  history:\n");
    defer empty_value.deinit();
    try testing.expectEqualStrings("", empty_value.problem);
    try testing.expect(empty_value.general.colorize);

    var scalar = loadForTest("colorize\n");
    defer scalar.deinit();
    try testing.expect(std.mem.indexOf(u8, scalar.problem, "top level") != null);

    var typo = loadForTest("genral:\n  colorize: true\ncache:\n  lruSize: 6\n");
    defer typo.deinit();
    try testing.expectEqualStrings("config.yaml: `genral` is not a top-level key (indentation?): ignored", typo.problem);
    try testing.expectEqual(@as(u16, 6), typo.cache.lru_size);
}
