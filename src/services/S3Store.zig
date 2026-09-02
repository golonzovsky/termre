// S3-compatible object store (AWS, Cloudflare R2, Backblaze B2, MinIO):
// path-style URLs and SigV4 request signing over std.http.
const Self = @This();
const std = @import("std");
const Entry = @import("Store.zig").Entry;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

allocator: std.mem.Allocator,
io: std.Io,
client: std.http.Client,
bucket: []const u8,
region: []const u8,
// Host only, e.g. `s3.eu-west-1.amazonaws.com` or `<acct>.r2.cloudflarestorage.com`.
endpoint: []const u8,
// Object key prefix inside the bucket, without trailing slash ("" allowed).
prefix: []const u8,
access_key: []const u8,
secret_key: []const u8,
session_token: []const u8,
// Unix seconds; injected so signing is testable.
now: *const fn () i64,

pub const Options = struct {
    bucket: []const u8,
    region: []const u8,
    endpoint: []const u8,
    prefix: []const u8 = "",
    access_key: []const u8,
    secret_key: []const u8,
    session_token: []const u8 = "",
    now: *const fn () i64,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .client = .{ .allocator = allocator, .io = io },
        .bucket = opts.bucket,
        .region = opts.region,
        .endpoint = opts.endpoint,
        .prefix = std.mem.trim(u8, opts.prefix, "/"),
        .access_key = opts.access_key,
        .secret_key = opts.secret_key,
        .session_token = opts.session_token,
        .now = opts.now,
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}

pub fn list(self: *Self, a: std.mem.Allocator, prefix: []const u8) ![]Entry {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const full_prefix = try self.objectKey(ta, prefix);
    const query = try std.fmt.allocPrint(ta, "list-type=2&prefix={s}", .{try uriEncode(ta, full_prefix, true)});
    const path = try std.fmt.allocPrint(ta, "/{s}", .{self.bucket});
    const resp = try self.request(ta, "GET", path, query, "");
    if (resp.status != 200) return statusError(resp.status);

    var out: std.ArrayList(Entry) = .empty;
    var rest = resp.body;
    while (std.mem.indexOf(u8, rest, "<Key>")) |i| {
        const after = rest[i + 5 ..];
        const end = std.mem.indexOf(u8, after, "</Key>") orelse break;
        const key = after[0..end];
        // Back to store-relative keys.
        const rel = if (self.prefix.len > 0 and std.mem.startsWith(u8, key, self.prefix) and key.len > self.prefix.len)
            key[self.prefix.len + 1 ..]
        else
            key;
        try out.append(a, .{ .key = try xmlUnescape(a, rel) });
        rest = after[end..];
    }
    return out.toOwnedSlice(a);
}

pub fn get(self: *Self, a: std.mem.Allocator, key: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const path = try self.objectPath(ta, key);
    const resp = try self.request(ta, "GET", path, "", "");
    if (resp.status == 404) return null;
    if (resp.status != 200) return statusError(resp.status);
    return try a.dupe(u8, resp.body);
}

pub fn put(self: *Self, key: []const u8, data: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const path = try self.objectPath(ta, key);
    const resp = try self.request(ta, "PUT", path, "", data);
    if (resp.status != 200) return statusError(resp.status);
}

fn statusError(status: u16) anyerror {
    return switch (status) {
        401, 403 => error.Forbidden,
        404 => error.NotFound,
        400 => error.BadRequest,
        500...599 => error.ServerError,
        else => error.RequestFailed,
    };
}

const Response = struct {
    status: u16,
    body: []u8,
};

// Signs and sends one request; `path` is the already-encoded canonical URI.
fn request(self: *Self, a: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8, payload: []const u8) !Response {
    const now: u64 = @intCast(@max(0, self.now()));
    const amz_date = amzDate(now);
    const date = amz_date[0..8];
    const payload_hash = hexSha256(payload);

    var extra: [5]std.http.Header = undefined;
    var n: usize = 0;
    extra[n] = .{ .name = "x-amz-content-sha256", .value = &payload_hash };
    n += 1;
    extra[n] = .{ .name = "x-amz-date", .value = &amz_date };
    n += 1;
    if (self.session_token.len > 0) {
        extra[n] = .{ .name = "x-amz-security-token", .value = self.session_token };
        n += 1;
    }

    const signed_headers: []const u8 = if (self.session_token.len > 0)
        "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
    else
        "host;x-amz-content-sha256;x-amz-date";
    const canonical_headers = if (self.session_token.len > 0)
        try std.fmt.allocPrint(a, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\nx-amz-security-token:{s}\n", .{ self.endpoint, &payload_hash, &amz_date, self.session_token })
    else
        try std.fmt.allocPrint(a, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{ self.endpoint, &payload_hash, &amz_date });

    const canonical = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, path, query, canonical_headers, signed_headers, &payload_hash });
    const scope = try std.fmt.allocPrint(a, "{s}/{s}/s3/aws4_request", .{ date, self.region });
    const sig_hex = signature(self.secret_key, date, self.region, &amz_date, scope, canonical);
    const auth = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ self.access_key, scope, signed_headers, &sig_hex });
    extra[n] = .{ .name = "authorization", .value = auth };
    n += 1;

    const url = if (query.len > 0)
        try std.fmt.allocPrint(a, "https://{s}{s}?{s}", .{ self.endpoint, path, query })
    else
        try std.fmt.allocPrint(a, "https://{s}{s}", .{ self.endpoint, path });

    var aw: std.Io.Writer.Allocating = .init(a);
    const result = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = if (std.mem.eql(u8, method, "PUT")) .PUT else .GET,
        .payload = if (std.mem.eql(u8, method, "PUT")) payload else null,
        .extra_headers = extra[0..n],
        .response_writer = &aw.writer,
    });
    return .{ .status = @intFromEnum(result.status), .body = aw.writer.buffered() };
}

fn objectKey(self: *Self, a: std.mem.Allocator, key: []const u8) ![]u8 {
    if (self.prefix.len == 0) return a.dupe(u8, key);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ self.prefix, key });
}

// `/<bucket>/<prefix>/<key>` with each segment URI-encoded.
fn objectPath(self: *Self, a: std.mem.Allocator, key: []const u8) ![]u8 {
    const full = try self.objectKey(a, key);
    return std.fmt.allocPrint(a, "/{s}/{s}", .{ self.bucket, try uriEncode(a, full, false) });
}

// ---- SigV4 -----------------------------------------------------------------

fn signature(secret: []const u8, date: []const u8, region: []const u8, amz_date: []const u8, scope: []const u8, canonical: []const u8) [64]u8 {
    var k1: [32]u8 = undefined;
    var k2: [32]u8 = undefined;
    var key_buf: [4 + 64]u8 = undefined;
    const k0 = std.fmt.bufPrint(&key_buf, "AWS4{s}", .{secret}) catch unreachable;
    HmacSha256.create(&k1, date, k0);
    HmacSha256.create(&k2, region, &k1);
    HmacSha256.create(&k1, "s3", &k2);
    HmacSha256.create(&k2, "aws4_request", &k1);
    const k = k2;

    const canonical_hash = hexSha256(canonical);
    var sts_buf: [256]u8 = undefined;
    const sts = std.fmt.bufPrint(&sts_buf, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, &canonical_hash }) catch unreachable;
    var sig: [32]u8 = undefined;
    HmacSha256.create(&sig, sts, &k);
    return std.fmt.bytesToHex(sig, .lower);
}

fn hexSha256(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// YYYYMMDD'T'HHMMSS'Z' from unix seconds.
fn amzDate(secs: u64) [16]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

// RFC 3986 unreserved characters pass through; `/` too unless `encode_slash`.
fn uriEncode(a: std.mem.Allocator, s: []const u8, encode_slash: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or (c == '/' and !encode_slash);
        if (keep) {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &.{ '%', hexDigit(c >> 4), hexDigit(c & 0xF) });
        }
    }
    return out.toOwnedSlice(a);
}

fn hexDigit(v: u8) u8 {
    return "0123456789ABCDEF"[v];
}

fn xmlUnescape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '&') {
            const pairs = .{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&#x2F;", "/" } };
            var matched = false;
            inline for (pairs) |p| {
                if (!matched and std.mem.startsWith(u8, s[i..], p[0])) {
                    try out.appendSlice(a, p[1]);
                    i += p[0].len - 1;
                    matched = true;
                }
            }
            if (!matched) try out.append(a, '&');
        } else try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

// AWS's published SigV4 example (GET Object, S3 API reference "Examples:
// Signature Calculations"): known key, date and canonical request.
test "sigv4 signature matches the AWS reference vector" {
    const canonical =
        "GET\n" ++
        "/test.txt\n" ++
        "\n" ++
        "host:examplebucket.s3.amazonaws.com\n" ++
        "range:bytes=0-9\n" ++
        "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n" ++
        "x-amz-date:20130524T000000Z\n" ++
        "\n" ++
        "host;range;x-amz-content-sha256;x-amz-date\n" ++
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const sig = signature("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524", "us-east-1", "20130524T000000Z", "20130524/us-east-1/s3/aws4_request", canonical);
    try std.testing.expectEqualStrings("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", &sig);
}

test "amzDate formats UTC" {
    try std.testing.expectEqualStrings("20130524T000000Z", &amzDate(1369353600));
}

test "uriEncode keeps unreserved and encodes slash on request" {
    const a = std.testing.allocator;
    const e = try uriEncode(a, "books/pdf-id_ab/x y.json", false);
    defer a.free(e);
    try std.testing.expectEqualStrings("books/pdf-id_ab/x%20y.json", e);
    const q = try uriEncode(a, "a/b", true);
    defer a.free(q);
    try std.testing.expectEqualStrings("a%2Fb", q);
}
