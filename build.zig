const std = @import("std");

fn addMupdfStatic(mod: *std.Build.Module, b: *std.Build, prefix: []const u8) void {
    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });

    mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmupdf.a", .{prefix}) });
    mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmupdf-third.a", .{prefix}) });

    mod.link_libc = true;
}

fn addMupdfDynamic(mod: *std.Build.Module, target: std.Target) void {
    if (target.os.tag == .macos and target.cpu.arch == .aarch64) {
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    } else if (target.os.tag == .macos and target.cpu.arch == .x86_64) {
        mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    } else if (target.os.tag == .linux) {
        mod.addIncludePath(.{ .cwd_relative = "/home/linuxbrew/.linuxbrew/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/home/linuxbrew/.linuxbrew/lib" });

        const linux_libs = [_][]const u8{
            "mupdf-third", "harfbuzz",
            "freetype",    "jbig2dec",
            "jpeg",        "openjp2",
            "gumbo",       "mujs",
        };
        for (linux_libs) |lib| mod.linkSystemLibrary(lib, .{});
    }
    mod.linkSystemLibrary("mupdf", .{});
    mod.linkSystemLibrary("z", .{});
    mod.link_libc = true;
}

// Zig 0.16's Aro translate-c rejects the `++*refs` / `drop = --*refs == 0`
// forms in mupdf's ref-count inlines ("invalid left-hand side to assignment"
// in the cImport). Rewrite them to equivalents it accepts. Idempotent, and
// only writes when something changed so mupdf isn't rebuilt every run.
fn patchMupdfContextH(b: *std.Build) void {
    const io = b.graph.io;
    const path = "deps/mupdf/include/mupdf/fitz/context.h";
    const a = b.allocator;
    const src = b.build_root.handle.readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch return;
    var out = std.mem.replaceOwned(u8, a, src, "++*refs;", "*refs += 1;") catch return;
    out = std.mem.replaceOwned(u8, a, out, "drop = --*refs == 0;", "*refs -= 1; drop = *refs == 0;") catch return;
    if (std.mem.eql(u8, out, src)) return;
    var f = b.build_root.handle.createFile(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fw = f.writer(io, &buf);
    fw.interface.writeAll(out) catch {};
    fw.interface.flush() catch {};
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var useVendorMupdf = true;
    const root = b.build_root.path orelse ".";
    const prefix = b.fmt("{s}/mupdf-out", .{root});
    const location = prefix;

    b.build_root.handle.access(b.graph.io, "deps/mupdf/Makefile", .{}) catch |err| {
        if (err == error.FileNotFound) {
            useVendorMupdf = false;
        } else {
            std.debug.print("Error: {s}\n", .{@errorName(err)});
            return;
        }
    };
    if (useVendorMupdf) patchMupdfContextH(b);

    const allocator = std.heap.page_allocator;
    var make_args: std.ArrayList([]const u8) = .empty;
    defer make_args.deinit(allocator);

    make_args.append(allocator, "make") catch unreachable;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    make_args.append(allocator, b.fmt("-j{d}", .{cpu_count})) catch unreachable;

    make_args.append(allocator, "-C") catch unreachable;
    make_args.append(allocator, b.fmt("{s}/deps/mupdf", .{root})) catch unreachable;

    if (target.result.os.tag == .linux) {
        make_args.append(allocator, "HAVE_X11=no") catch unreachable;
        make_args.append(allocator, "HAVE_GLUT=no") catch unreachable;
    }

    make_args.append(allocator, "XCFLAGS=-w -DTOFU -DTOFU_CJK -DFZ_ENABLE_PDF=1 " ++
        "-DFZ_ENABLE_XPS=0 -DFZ_ENABLE_SVG=0 -DFZ_ENABLE_CBZ=0 " ++
        "-DFZ_ENABLE_IMG=0 -DFZ_ENABLE_HTML=0 -DFZ_ENABLE_EPUB=0") catch unreachable;
    make_args.append(allocator, "tools=no") catch unreachable;
    make_args.append(allocator, "apps=no") catch unreachable;

    const prefix_arg = b.fmt("prefix={s}", .{prefix});
    make_args.append(allocator, prefix_arg) catch unreachable;
    make_args.append(allocator, "install") catch unreachable;

    const mupdf_build_step = b.addSystemCommand(make_args.items);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "re",
        .root_module = exe_mod,
    });
    exe.headerpad_max_install_names = true;

    if (target.result.os.tag == .macos) {
        exe_mod.linkFramework("CoreGraphics", .{});
    }

    const deps = .{
        .vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }),
        .fastb64z = b.dependency("fastb64z", .{ .target = target, .optimize = optimize }),
        .fzwatch = b.dependency("fzwatch", .{ .target = target, .optimize = optimize }),
    };

    const fzwatch_mod = deps.fzwatch.module("fzwatch");
    if (target.result.os.tag == .macos) {
        fzwatch_mod.linkFramework("CoreServices", .{});
        fzwatch_mod.link_libc = true;
    }

    exe_mod.addImport("fastb64z", deps.fastb64z.module("fastb64z"));
    exe_mod.addImport("vaxis", deps.vaxis.module("vaxis"));
    exe_mod.addImport("fzwatch", fzwatch_mod);

    exe_mod.addAnonymousImport("metadata", .{ .root_source_file = b.path("build.zig.zon") });

    if (useVendorMupdf) {
        exe.step.dependOn(&mupdf_build_step.step);
        addMupdfStatic(exe_mod, b, location);
        b.installArtifact(exe);
        b.getInstallStep().dependOn(&mupdf_build_step.step);
    } else {
        addMupdfDynamic(exe_mod, target.result);
        b.installArtifact(exe);
    }

    exe_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src/mupdf-z", .{root}) });
    exe_mod.addCSourceFile(.{ .file = .{ .cwd_relative = b.fmt("{s}/src/mupdf-z/fitz-z.c", .{root}) } });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);
}
