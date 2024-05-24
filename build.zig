const std = @import("std");

fn prepareMiniaudio(b: *std.Build) std.Build.LazyPath {
    const tool_run = b.addSystemCommand(&.{"patch"});
    tool_run.addFileArg(b.path("miniaudio/miniaudio.h"));

    tool_run.addArg("-o");
    const ret = tool_run.addOutputFileArg("miniaudio.h");
    tool_run.addFileArg(b.path("miniaudio/zig_18247.patch"));
    b.getInstallStep().dependOn(&tool_run.step);
    return ret;
}

fn setupWhisper(b: *std.Build, exe: *std.Build.Step.Compile) void {
    // Debug build of whisper is unreasonably slow. Create a library to allow
    // us to always compile in release
    //
    // Bypass whisper build system for simplicity, if this becomes a problem we
    // can always leverage theirs, but for now this seems like it integrates
    // better with our project with no downsides
    const lib = b.addStaticLibrary(.{
        .name = "whisper",
        .root_source_file = null,
        .target = exe.root_module.resolved_target.?,
        .optimize = std.builtin.OptimizeMode.ReleaseFast,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    const whisper_files: []const []const u8 = &.{
        "ggml.c", "ggml-alloc.c", "ggml-backend.c", "ggml-quants.c", "whisper.cpp",
    };

    for (whisper_files) |f| {
        lib.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "vendor/whisper.cpp", f })) });
    }

    if (exe.root_module.resolved_target.?.result.os.tag == .linux) {
        lib.defineCMacro("_GNU_SOURCE", "");
    }

    exe.addIncludePath(b.path("vendor/whisper.cpp"));
    exe.linkLibrary(lib);
}

fn setupRustGui(b: *std.Build, opt: std.builtin.OptimizeMode) !std.Build.LazyPath {
    const tool_run = b.addSystemCommand(&.{"cargo"});
    tool_run.setCwd(b.path("src/gui/rust"));
    tool_run.addArgs(&.{
        "build",
    });

    var opt_path: []const u8 = undefined;
    switch (opt) {
        .ReleaseSafe,
        .ReleaseFast,
        .ReleaseSmall,
        => {
            tool_run.addArg("--release");
            opt_path = "release";
        },
        .Debug => {
            opt_path = "debug";
        },
    }

    const generated = try b.allocator.create(std.Build.GeneratedFile);
    generated.* = .{
        .step = &tool_run.step,
        .path = try b.build_root.join(b.allocator, &.{ "src/gui/rust/target", opt_path, "libgui.a" }),
    };

    const lib_path = std.Build.LazyPath{
        .generated = generated,
    };

    return lib_path;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const fake_ui = b.option(bool, "fake_ui", "whether we should build the fake UI") orelse false;

    const exe = b.addExecutable(.{
        .name = "video-editor",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = opt,
    });

    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avutil");

    if (fake_ui) {
        exe.addCSourceFile(.{
            .file = b.path("src/gui/mock/mock_gui.c"),
            .flags = &.{ "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
        });
    } else {
        const libgui_path = try setupRustGui(b, opt);
        exe.addLibraryPath(libgui_path.dirname());
        exe.linkSystemLibrary("gui");
    }

    setupWhisper(b, exe);

    exe.addCSourceFile(.{ .file = b.path("src/miniaudio_impl.c") });
    exe.addIncludePath(b.path("src/gui"));

    const miniaudio_path = prepareMiniaudio(b);
    exe.addIncludePath(miniaudio_path.dirname());
    exe.linkLibC();
    exe.linkLibCpp();
    b.installArtifact(exe);
}
