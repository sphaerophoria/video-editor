const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const FrameRenderer = @import("FrameRenderer.zig");
const decoder = @import("decoder.zig");
const audio = @import("audio.zig");
const App = @import("App.zig");
const AudioRenderer = @import("AudioRenderer.zig");

const ArgParseError = std.process.ArgIterator.InitError;

const Args = struct {
    it: std.process.ArgIterator,
    input: [:0]const u8,

    const Switch = enum {
        @"--input",
        @"--help",

        fn parse(s: []const u8) ?Switch {
            inline for (std.meta.fields(Switch)) |f| {
                if (std.mem.eql(u8, f.name, s)) {
                    return @enumFromInt(f.value);
                }
            }

            return null;
        }
    };

    fn print(comptime fmt: []const u8, params: anytype) void {
        std.io.getStdErr().writer().print(fmt, params) catch {};
    }

    pub fn init(alloc: std.mem.Allocator) ArgParseError!Args {
        var args = try std.process.argsWithAllocator(alloc);

        var input: ?[:0]const u8 = null;
        const process_name = args.next() orelse "video-editor";
        while (args.next()) |arg| {
            const s = Switch.parse(arg) orelse {
                print("unrecognized argument: {s}\n", .{arg});
                help(process_name);
            };

            switch (s) {
                .@"--input" => {
                    input = args.next() orelse {
                        print("--input provided with no file\n", .{});
                        help(process_name);
                    };
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .it = args,
            .input = input orelse {
                unreachable;
            },
        };
    }

    fn help(process_name: []const u8) noreturn {
        print("Usage: {s} [ARGS]\n\nARGS:\n", .{process_name});

        inline for (std.meta.fields(Switch)) |s| {
            print("{s}: ", .{s.name});
            const value: Switch = @enumFromInt(s.value);
            switch (value) {
                .@"--input" => {
                    print("File to work with", .{});
                },
                .@"--help" => {
                    print("Show this help", .{});
                },
            }
            print("\n", .{});
        }

        std.process.exit(1);
    }

    pub fn deinit(self: *Args) void {
        self.it.deinit();
    }
};

fn makeAudioPlayer(alloc: Allocator, dec: *decoder.VideoDecoder) !?*audio.Player {
    var audio_player: ?*audio.Player = null;

    var streams = dec.streams();
    while (try streams.next()) |stream| {
        switch (stream) {
            .audio => |params| {
                audio_player = try audio.Player.init(alloc, .{
                    .channels = params.num_channels,
                    .format = params.format,
                    .sample_rate = params.sample_rate,
                });
                // No UI for dealing with multiple streams, video ignored
                break;
            },
            else => {},
        }
    }

    return audio_player;
}

fn main_loop(refs: App.AppRefs) !void {
    // If main thread init fails, we need to close the GUI, but if the GUI
    // hadn't launched yet it will miss the shutdown notification and stay
    // open forever
    c.gui_wait_start(refs.gui);
    defer c.gui_close(refs.gui);

    var app = try App.init(refs);
    try app.run();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.init(alloc);
    defer args.deinit();

    var dec = try decoder.VideoDecoder.init(alloc, args.input);
    defer dec.deinit();

    var audio_renderer = try AudioRenderer.init(alloc, args.input);
    defer audio_renderer.deinit();

    var frame_renderer_shared = FrameRenderer.SharedData{};
    defer frame_renderer_shared.deinit();

    var frame_renderer = FrameRenderer.init(&frame_renderer_shared);

    var app_state = App.AppState.init();

    const audio_player = try makeAudioPlayer(alloc, &dec);
    defer if (audio_player) |p| p.deinit();

    const gui = c.gui_init(&app_state);
    defer c.gui_free(gui);

    const app_refs: App.AppRefs = .{
        .alloc = alloc,
        .frame_renderer = &frame_renderer_shared,
        .gui = gui,
        .app_state = &app_state,
        .dec = &dec,
        .audio_player = audio_player,
    };

    const main_loop_thread = try std.Thread.spawn(.{}, main_loop, .{app_refs});
    c.gui_run(gui, &frame_renderer, &audio_renderer);
    main_loop_thread.join();
}
