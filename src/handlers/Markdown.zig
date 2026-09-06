// Consumes structured page events from `fz_extract_pages_z` and emits markdown
// to an `std.Io.Writer`. All formatting heuristics live here.
const Self = @This();
const std = @import("std");

pub const Char = extern struct {
    codepoint: u32,
    bold: u8,
    italic: u8,
    mono: u8,
    _pad: u8,
    size: f32,
    origin_y: f32,
};

const event_page_start = 0;
const event_line = 1;
const event_block_end = 2;
const event_image = 3;
const event_page_end = 4;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
body_size: f32 = 0,
chars: std.ArrayList(Char) = .empty,
line_offsets: std.ArrayList(u32) = .empty, // offset into `chars` where each line begins
in_code_block: bool = false,
write_failed: bool = false,
// Called at the start of every page (absolute page index), before its text;
// used for chapter headings and page markers.
on_page: ?PageHook = null,
on_page_ctx: ?*anyopaque = null,
first_page: u16 = 0,
pages_seen: u16 = 0,

pub const PageHook = *const fn (ctx: *anyopaque, page: u16, writer: *std.Io.Writer) anyerror!void;

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Self {
    return .{ .allocator = allocator, .writer = writer };
}

pub fn deinit(self: *Self) void {
    self.chars.deinit(self.allocator);
    self.line_offsets.deinit(self.allocator);
}

pub fn finalize(self: *Self) !void {
    self.closeCodeBlock();
}

pub fn eventCallback(ud: ?*anyopaque, kind: c_int, chars: ?[*]const Char, n: c_int, str: ?[*:0]const u8) callconv(.c) void {
    const self = @as(*Self, @ptrCast(@alignCast(ud.?)));
    self.handle(kind, chars, n, str) catch {
        self.write_failed = true;
    };
}

fn handle(self: *Self, kind: c_int, chars_ptr: ?[*]const Char, n: c_int, str: ?[*:0]const u8) !void {
    switch (kind) {
        event_page_start => {
            if (chars_ptr) |p| self.body_size = p[0].size;
            if (self.on_page) |hook| {
                try self.flushBlock();
                self.closeCodeBlock();
                try hook(self.on_page_ctx.?, self.first_page + self.pages_seen, self.writer);
            }
            self.pages_seen += 1;
        },
        event_line => if (chars_ptr) |p| {
            const slice = p[0..@intCast(n)];
            try self.line_offsets.append(self.allocator, @intCast(self.chars.items.len));
            try self.chars.appendSlice(self.allocator, slice);
        },
        event_block_end => try self.flushBlock(),
        event_image => if (str) |s| {
            self.closeCodeBlock();
            try self.writer.print("![]({s})\n\n", .{std.mem.span(s)});
        },
        event_page_end => {},
        else => {},
    }
}

fn flushBlock(self: *Self) !void {
    defer {
        self.chars.clearRetainingCapacity();
        self.line_offsets.clearRetainingCapacity();
    }
    if (self.line_offsets.items.len == 0) return;

    if (blockIsAllMono(self.chars.items)) {
        try self.openCodeBlock();
        try self.emitCode();
        return;
    }

    self.closeCodeBlock();

    const first_line = self.lineSlice(0);
    var max_size: f32 = 0;
    for (first_line) |ch| {
        if (ch.codepoint > 32 and ch.size > max_size) max_size = ch.size;
    }
    var body_start: usize = 0;
    if (self.body_size > 0 and max_size / self.body_size >= 1.2) {
        const ratio = max_size / self.body_size;
        const prefix: []const u8 = if (ratio >= 1.7) "# " else if (ratio >= 1.4) "## " else "### ";
        try self.writer.writeAll(prefix);
        try self.emitPlainChars(first_line, true);
        try self.writer.writeAll("\n\n");
        body_start = 1;
        if (body_start >= self.line_offsets.items.len) return;
    }

    try self.emitParagraph(body_start);
}

fn lineSlice(self: *const Self, i: usize) []const Char {
    const start = self.line_offsets.items[i];
    const end: u32 = if (i + 1 < self.line_offsets.items.len) self.line_offsets.items[i + 1] else @intCast(self.chars.items.len);
    return self.chars.items[start..end];
}

fn blockIsAllMono(chars: []const Char) bool {
    var saw_any = false;
    for (chars) |ch| {
        if (ch.codepoint <= 32 or isInvisible(ch.codepoint)) continue;
        saw_any = true;
        if (ch.mono == 0) return false;
    }
    return saw_any;
}

fn openCodeBlock(self: *Self) !void {
    if (self.in_code_block) return;
    try self.writer.writeAll("```\n");
    self.in_code_block = true;
}

fn closeCodeBlock(self: *Self) void {
    if (!self.in_code_block) return;
    self.writer.writeAll("```\n\n") catch {};
    self.in_code_block = false;
}

// Emit chars with no styling markers; `dedupe_space` collapses runs of
// whitespace into a single space (used for headings; code blocks preserve
// indentation so they pass false).
fn emitPlainChars(self: *Self, chars: []const Char, dedupe_space: bool) !void {
    var last_space = true;
    for (chars) |ch| {
        if (isInvisible(ch.codepoint)) continue;
        if (ch.codepoint <= 32) {
            if (!dedupe_space or !last_space) {
                try self.writer.writeByte(' ');
                last_space = true;
            }
            continue;
        }
        try writeRune(self.writer, ch.codepoint);
        last_space = false;
    }
}

fn emitCode(self: *Self) !void {
    for (0..self.line_offsets.items.len) |i| {
        try self.emitPlainChars(self.lineSlice(i), false);
        try self.writer.writeByte('\n');
    }
}

fn emitParagraph(self: *Self, start_line: usize) !void {
    var pp = ParaState{};
    var li = start_line;
    while (li < self.line_offsets.items.len) : (li += 1) {
        const line = self.lineSlice(li);
        try self.emitParaLine(&pp, line);
        if (li + 1 < self.line_offsets.items.len and !pp.last_was_space) pp.pending_space = true;
    }
    try self.syncStyles(&pp, false, false, false);
    try self.writer.writeAll("\n\n");
}

const ParaState = struct {
    in_bold: bool = false,
    in_italic: bool = false,
    in_mono: bool = false,
    last_was_space: bool = true,
    pending_space: bool = false,
};

// Per-line discriminator for superscript detection. Just `max_size` is cached
// here; the relevant baseline is computed per-char against the *nearest*
// body-size neighbor (mupdf sometimes groups two visual lines into one stext
// line, so a line-wide average is unreliable).
const LineMetrics = struct {
    max_size: f32 = 0,
};

fn computeMetrics(chars: []const Char) LineMetrics {
    var m = LineMetrics{};
    for (chars) |c| {
        if (c.codepoint > 32 and c.size > m.max_size) m.max_size = c.size;
    }
    return m;
}

fn isSuper(chars: []const Char, idx: usize, m: LineMetrics) bool {
    const ch = chars[idx];
    if (m.max_size <= 0 or ch.codepoint <= 32) return false;
    if (ch.size >= m.max_size * 0.85) return false;
    // Use the closest body-size char's baseline as reference.
    var best_dist: usize = std.math.maxInt(usize);
    var baseline: f32 = 0;
    for (chars, 0..) |c, i| {
        if (c.codepoint <= 32 or c.size < m.max_size * 0.95) continue;
        const dist = if (i > idx) i - idx else idx - i;
        if (dist < best_dist) {
            best_dist = dist;
            baseline = c.origin_y;
        }
    }
    if (best_dist == std.math.maxInt(usize)) return false;
    return ch.origin_y < baseline - 1.0;
}

fn isInvisible(cp: u32) bool {
    return cp == 0xFFFD // replacement char
    or cp == 0x00AD // soft hyphen
    or (cp >= 0xFE00 and cp <= 0xFE0F); // variation selectors
}

fn emitParaLine(self: *Self, p: *ParaState, chars: []const Char) !void {
    const metrics = computeMetrics(chars);
    var i: usize = 0;
    while (i < chars.len) : (i += 1) {
        const ch = chars[i];
        if (isInvisible(ch.codepoint)) continue;
        if (ch.codepoint <= 32) {
            if (!p.last_was_space) p.pending_space = true;
            continue;
        }
        if (try self.tryEmitSuperscript(p, chars, &i, metrics)) continue;
        if (try self.tryEmitTexQuote(p, chars, &i)) continue;
        try self.emitChar(p, ch);
    }
}

// Emit a run of consecutive superscript chars (Unicode glyphs when all in our
// digit/symbol map, `<sup>…</sup>` fallback otherwise). Advances `*idx` past the
// run. Returns true if a run was emitted.
fn tryEmitSuperscript(self: *Self, p: *ParaState, chars: []const Char, idx: *usize, m: LineMetrics) !bool {
    if (!isSuper(chars, idx.*, m)) return false;
    var j = idx.*;
    while (j < chars.len and isSuper(chars, j, m)) : (j += 1) {}
    const run = chars[idx.*..j];

    var all_translatable = true;
    for (run) |sch| {
        if (asSuperscript(sch.codepoint) == null) {
            all_translatable = false;
            break;
        }
    }

    try self.flushPendingSpace(p, run[0].bold != 0, run[0].italic != 0, run[0].mono != 0);
    if (!all_translatable and p.in_mono) {
        try self.writer.writeByte('`');
        p.in_mono = false;
    }
    if (all_translatable) {
        for (run) |sch| try writeRune(self.writer, asSuperscript(sch.codepoint).?);
    } else {
        try self.writer.writeAll("<sup>");
        for (run) |sch| try writeRune(self.writer, sch.codepoint);
        try self.writer.writeAll("</sup>");
    }
    p.last_was_space = false;
    idx.* = j - 1; // outer loop increments
    return true;
}

// Normalize TeX-style double quotes (`` and '' → "). Advances `*idx` past the
// second char of the pair when consumed.
fn tryEmitTexQuote(self: *Self, p: *ParaState, chars: []const Char, idx: *usize) !bool {
    const ch = chars[idx.*];
    if (ch.codepoint != '`' and ch.codepoint != '\'') return false;
    if (idx.* + 1 >= chars.len or chars[idx.* + 1].codepoint != ch.codepoint) return false;
    // Close mono around the literal " — markdown's `code` would swallow it.
    try self.flushPendingSpace(p, p.in_bold, p.in_italic, false);
    try self.writer.writeByte('"');
    p.last_was_space = false;
    idx.* += 1;
    return true;
}

fn emitChar(self: *Self, p: *ParaState, ch: Char) !void {
    const rune: u32 = if (ch.codepoint == '`') '\'' else ch.codepoint; // lone ` → '
    const bold = ch.bold != 0;
    const italic = ch.italic != 0;
    const mono = ch.mono != 0;
    try self.flushPendingSpace(p, bold, italic, mono);
    try self.syncStyles(p, bold, italic, mono);
    try writeRune(self.writer, rune);
    p.last_was_space = false;
}

// Emit a deferred space, closing any emph that would otherwise leave a marker
// preceded by whitespace (CommonMark rejects `**foo **`). Caller passes the
// styles of the upcoming char so transitions out of the run close before the
// space, and styles that continue stay open.
fn flushPendingSpace(self: *Self, p: *ParaState, next_bold: bool, next_italic: bool, next_mono: bool) !void {
    if (!p.pending_space) return;
    if (p.in_mono and !next_mono) {
        try self.writer.writeByte('`');
        p.in_mono = false;
    }
    if (p.in_italic and !next_italic) {
        try self.writer.writeByte('*');
        p.in_italic = false;
    }
    if (p.in_bold and !next_bold) {
        try self.writer.writeAll("**");
        p.in_bold = false;
    }
    try self.writer.writeByte(' ');
    p.last_was_space = true;
    p.pending_space = false;
}

fn syncStyles(self: *Self, p: *ParaState, bold: bool, italic: bool, mono: bool) !void {
    if (p.in_mono and !mono) {
        try self.writer.writeByte('`');
        p.in_mono = false;
    }
    if (p.in_italic and !italic) {
        try self.writer.writeByte('*');
        p.in_italic = false;
    }
    if (p.in_bold and !bold) {
        try self.writer.writeAll("**");
        p.in_bold = false;
    }
    if (!p.in_bold and bold) {
        try self.writer.writeAll("**");
        p.in_bold = true;
    }
    if (!p.in_italic and italic) {
        try self.writer.writeByte('*');
        p.in_italic = true;
    }
    if (!p.in_mono and mono) {
        try self.writer.writeByte('`');
        p.in_mono = true;
    }
}

fn asSuperscript(cp: u32) ?u32 {
    return switch (cp) {
        '0' => 0x2070,
        '1' => 0x00B9,
        '2' => 0x00B2,
        '3' => 0x00B3,
        '4' => 0x2074,
        '5' => 0x2075,
        '6' => 0x2076,
        '7' => 0x2077,
        '8' => 0x2078,
        '9' => 0x2079,
        '+' => 0x207A,
        '-' => 0x207B,
        '=' => 0x207C,
        '(' => 0x207D,
        ')' => 0x207E,
        'n' => 0x207F,
        'i' => 0x2071,
        else => null,
    };
}

fn writeRune(w: *std.Io.Writer, rune: u32) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(@intCast(rune), &buf);
    try w.writeAll(buf[0..len]);
}
