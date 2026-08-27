const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");

pub const Key = struct {
    colorize: bool,
    page: u16,
    width_mode: bool,
    zoom: u32,
    crop: bool,
    spread: bool,
    shift_x: i32,
    // Selection generation: 0 for pages without an active selection; bumped on
    // every selection change so the page with baked-in highlights re-renders once.
    sel: u32,
};
pub const CachedImage = struct {
    image: vaxis.Image,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
};

const Node = struct {
    key: Key,
    value: CachedImage,
    prev: ?*Node,
    next: ?*Node,
};

allocator: std.mem.Allocator,
map: std.AutoHashMap(Key, *Node),
head: ?*Node,
tail: ?*Node,
lru_size: u16,
// Terminal-side footprint bound: the terminal stores decoded pixels for every
// live image, and its own storage quota silently evicts (including the visible
// page) when exceeded. Entry count alone doesn't bound bytes at high zoom.
budget_bytes: usize,
total_bytes: usize,

pub fn init(allocator: std.mem.Allocator, lru_size: u16, budget_bytes: usize) Self {
    return .{
        .allocator = allocator,
        .map = std.AutoHashMap(Key, *Node).init(allocator),
        .head = null,
        .tail = null,
        .lru_size = lru_size,
        .budget_bytes = budget_bytes,
        .total_bytes = 0,
    };
}

fn cost(image: CachedImage) usize {
    return @as(usize, image.image.width) * @as(usize, image.image.height) * 4;
}

pub fn deinit(self: *Self) void {
    var current = self.head;
    while (current) |node| {
        const next = node.next;
        self.allocator.destroy(node);
        current = next;
    }

    self.map.deinit();
}

// Empties the cache, handing the displaced images to the caller, which owns
// freeing them terminal-side (deferred until after the next render to avoid
// flicker).
pub fn clearInto(self: *Self, allocator: std.mem.Allocator, out: *std.ArrayList(CachedImage)) void {
    var current = self.head;
    while (current) |node| {
        const next = node.next;
        out.append(allocator, node.value) catch {};
        self.allocator.destroy(node);
        current = next;
    }

    self.map.clearRetainingCapacity();
    self.head = null;
    self.tail = null;
    self.total_bytes = 0;
}

pub fn contains(self: *Self, key: Key) bool {
    return self.map.contains(key);
}

pub fn get(self: *Self, key: Key) ?CachedImage {
    const node = self.map.get(key) orelse return null;
    self.moveToFront(node);
    return node.value;
}

// Inserts and evicts from the LRU tail until both the entry count and the
// byte budget hold; displaced images land in `evicted` and the caller owns
// freeing them terminal-side.
pub fn put(self: *Self, key: Key, image: CachedImage, gpa: std.mem.Allocator, evicted: *std.ArrayList(CachedImage)) !void {
    if (self.map.get(key)) |node| {
        self.moveToFront(node);
        return;
    }

    const new_node = try self.allocator.create(Node);
    new_node.* = .{
        .key = key,
        .value = image,
        .prev = null,
        .next = null,
    };

    try self.map.put(key, new_node);
    self.addToFront(new_node);
    self.total_bytes += cost(image);

    while (self.map.count() > 1 and
        (self.map.count() > self.lru_size or self.total_bytes > self.budget_bytes))
    {
        const tail_node = self.tail orelse break;
        evicted.append(gpa, tail_node.value) catch break;
        _ = self.remove(tail_node.key);
    }
}

// Removes an entry, returning it so the caller can free its terminal-side image.
pub fn take(self: *Self, key: Key) ?CachedImage {
    const node = self.map.get(key) orelse return null;
    const value = node.value;
    self.total_bytes -= cost(value);
    _ = self.map.remove(key);
    self.removeNode(node);
    self.allocator.destroy(node);
    return value;
}

fn remove(self: *Self, key: Key) bool {
    const node = self.map.get(key) orelse return false;
    self.total_bytes -= cost(node.value);
    _ = self.map.remove(key);

    self.removeNode(node);
    self.allocator.destroy(node);

    return true;
}

fn addToFront(self: *Self, node: *Node) void {
    node.next = self.head;
    node.prev = null;

    if (self.head) |head| {
        head.prev = node;
    } else {
        self.tail = node;
    }

    self.head = node;
}

fn removeNode(self: *Self, node: *Node) void {
    if (node.prev) |prev| {
        prev.next = node.next;
    } else {
        self.head = node.next;
    }

    if (node.next) |next| {
        next.prev = node.prev;
    } else {
        self.tail = node.prev;
    }
}

fn moveToFront(self: *Self, node: *Node) void {
    if (self.head == node) return;
    self.removeNode(node);
    self.addToFront(node);
}
