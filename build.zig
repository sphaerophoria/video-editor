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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

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
    exe.addCSourceFile(.{ .file = b.path("glad/src/glad.c") });
    exe.addCSourceFile(.{ .file = b.path("src/miniaudio_impl.c") });
    exe.addIncludePath(b.path("glad/include"));
    const miniaudio_path = prepareMiniaudio(b);
    exe.addIncludePath(miniaudio_path.dirname());
    exe.linkLibC();
    b.installArtifact(exe);
}
