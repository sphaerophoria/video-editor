const std = @import("std");
const audio = @import("audio.zig");
const Allocator = std.mem.Allocator;

child: std.process.Child,

const WavWriter = @This();

// ffmpeg -f f32le -ar 48k -ac 1 -i out.bin out.wav

pub fn init(alloc: Allocator, sample_rate: usize, channels: usize, format: audio.Format, output_path: []const u8) !WavWriter {
    const ffmpeg_format_string = switch(format) {
        .f32 => "f32le",
    };

    const sample_rate_string = try std.fmt.allocPrint(alloc, "{d}", .{sample_rate});
    defer alloc.free(sample_rate_string);

    const channels_string = try std.fmt.allocPrint(alloc, "{d}", .{channels});
    defer alloc.free(channels_string);

    std.debug.print("init\n", .{});
    var child = std.process.Child.init(&.{
        "ffmpeg", "-y", "-f", ffmpeg_format_string, "-ar", sample_rate_string, "-ac", channels_string, "-i", "-", output_path
    }, alloc);

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    return .{
        .child = child,
    };
}

pub fn writeAudio(self: *WavWriter, buf: []const u8) !void {
    std.debug.print("buf size: {d}\n", .{buf.len});
    try self.child.stdin.?.writeAll(buf);
}

pub fn deinit(self: *WavWriter) void {
    self.child.stdin.?.close();
    _ = std.posix.waitpid(self.child.id, 0);
}
