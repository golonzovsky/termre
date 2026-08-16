const Self = @This();
const std = @import("std");
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

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) KeyMap {
        var keymap = KeyMap{};
        if (val != .object) return keymap;

        inline for (std.meta.fields(KeyMap)) |key| {
            @field(keymap, key.name) = parseKeyBinding(val.object, key.name, allocator, @field(
                keymap,
                key.name,
            ));
        }

        return keymap;
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
    dpi: f32 = 96.0,
    // whole number (possibly 0)
    history: u32 = 1000,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) General {
        var general = General{};
        if (val != .object) return general;

        inline for (std.meta.fields(General)) |f| {
            // white/black accept hex-string or {rgb} forms, not plain integers.
            const is_color = comptime std.mem.eql(u8, f.name, "white") or std.mem.eql(u8, f.name, "black");
            if (!is_color) {
                @field(general, f.name) = parseType(f.type, val.object, f.name, allocator, @field(general, f.name));
            }
        }

        if (val.object.get("white")) |white| {
            if (parseRGB(white, allocator)) |rgb| general.white = rgbToInt(rgb);
        }
        if (val.object.get("black")) |black| {
            if (parseRGB(black, allocator)) |rgb| general.black = rgbToInt(rgb);
        }

        return general;
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

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) Cache {
        return parseFields(Cache, val, allocator);
    }
};

arena: std.heap.ArenaAllocator,

key_map: KeyMap = .{},
file_monitor: FileMonitor = .{},
general: General = .{},
status_bar: StatusBar = .{},
cache: Cache = .{},

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) Self {
    var self = Self{ .arena = std.heap.ArenaAllocator.init(allocator) };
    const arena_allocator = self.arena.allocator();

    const home = env.get("HOME") orelse return self;

    var path: []u8 = "";
    if (env.get("XDG_CONFIG_HOME")) |x| {
        path = std.fmt.allocPrint(allocator, "{s}/termre/config.json", .{x}) catch return self;
    } else path = std.fmt.allocPrint(allocator, "{s}/.config/termre/config.json", .{home}) catch return self;
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var content: ?[]u8 = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch null;
    if (content == null) {
        // Pre-rename fallback: read an existing fancy-cat config once; writes
        // (the auto-created empty file) go to the termre path.
        const legacy: ?[]u8 = if (env.get("XDG_CONFIG_HOME")) |x|
            std.fmt.allocPrint(allocator, "{s}/fancy-cat/config.json", .{x}) catch null
        else
            std.fmt.allocPrint(allocator, "{s}/.config/fancy-cat/config.json", .{home}) catch null;
        if (legacy) |lp| {
            defer allocator.free(lp);
            content = cwd.readFileAlloc(io, lp, allocator, .limited(1024 * 1024)) catch null;
        }
    }
    if (content == null) {
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
        const file = cwd.createFile(io, path, .{}) catch return self;
        file.close(io);
        return self;
    }
    defer allocator.free(content.?);

    if (content.?.len == 0) return self;

    var parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content.?, .{}) catch return self;
    defer parsed.deinit();

    if (parsed.value.object.get("KeyMap")) |key_map| self.key_map = KeyMap.parse(key_map, arena_allocator);
    if (parsed.value.object.get("FileMonitor")) |file_monitor| self.file_monitor = FileMonitor.parse(file_monitor, arena_allocator);
    if (parsed.value.object.get("General")) |general| self.general = General.parse(general, arena_allocator);
    if (parsed.value.object.get("StatusBar")) |status_bar| self.status_bar = StatusBar.parse(status_bar, arena_allocator);
    if (parsed.value.object.get("Cache")) |cache| self.cache = Cache.parse(cache, arena_allocator);

    return self;
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
    binding.codepoint = vaxis.Key.name_map.get(key_str) orelse @as(u21, key_str[0]);

    var mods = vaxis.Key.Modifiers{};
    const modifiers = val.object.get("modifiers") orelse return binding;
    if (modifiers != .array) return binding;

    for (modifiers.array.items) |mod| {
        if (mod != .string) continue;
        if (std.mem.eql(u8, mod.string, "shift")) mods.shift = true;
        if (std.mem.eql(u8, mod.string, "alt")) mods.alt = true;
        if (std.mem.eql(u8, mod.string, "ctrl")) mods.ctrl = true;
        if (std.mem.eql(u8, mod.string, "super")) mods.super = true;
        if (std.mem.eql(u8, mod.string, "hyper")) mods.hyper = true;
        if (std.mem.eql(u8, mod.string, "meta")) mods.meta = true;
        if (std.mem.eql(u8, mod.string, "caps_lock")) mods.caps_lock = true;
        if (std.mem.eql(u8, mod.string, "num_lock")) mods.num_lock = true;
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

// Fills every field of T from the JSON object, keeping the default on miss/mismatch.
fn parseFields(comptime T: type, val: std.json.Value, allocator: std.mem.Allocator) T {
    var result = T{};
    if (val != .object) return result;
    inline for (std.meta.fields(T)) |f| {
        @field(result, f.name) = parseType(f.type, val.object, f.name, allocator, @field(result, f.name));
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
    inline for (std.meta.fields(vaxis.Cell.Style)) |field| {
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
