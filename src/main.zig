const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const WordTimestampGenerator = @import("WordTimestampGenerator.zig");
const FrameRenderer = @import("FrameRenderer.zig");
const decoder = @import("decoder.zig");
const audio = @import("audio.zig");
const save = @import("save.zig");
const App = @import("App.zig");
const AudioRenderer = @import("AudioRenderer.zig");
const ClipManager = @import("ClipManager.zig");

const ArgParseError = std.process.ArgIterator.InitError;

const Args = struct {
    it: std.process.ArgIterator,
    input: [:0]const u8,
    output: [:0]const u8,
    generate_subtitles: bool,

    const Switch = enum {
        @"--input",
        @"--output",
        @"--skip-subtitles",
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
        var output: ?[:0]const u8 = null;
        var generate_subtitles: bool = true;
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
                .@"--output" => {
                    output = args.next() orelse {
                        print("--output provided with no file\n", .{});
                        help(process_name);
                    };
                },
                .@"--skip-subtitles" => {
                    generate_subtitles = false;
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .it = args,
            .input = input orelse {
                print("input not provided\n", .{});
                help(process_name);
            },
            .output = output orelse {
                print("output not provided\n", .{});
                help(process_name);
            },
            .generate_subtitles = generate_subtitles,
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
                .@"--output" => {
                    print("Save file", .{});
                },
                .@"--skip-subtitles" => {
                    print("Skip subtitle generation", .{});
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

    const alloc = if (builtin.mode == .Debug)
        gpa.allocator()
    else
        std.heap.c_allocator;

    var args = try Args.init(alloc);
    defer args.deinit();

    var dec = try decoder.VideoDecoder.init(alloc, args.input);
    defer dec.deinit();

    var audio_renderer = try AudioRenderer.init(alloc, args.input);
    defer audio_renderer.deinit();

    var frame_renderer_shared = FrameRenderer.SharedData{};
    defer frame_renderer_shared.deinit();

    var frame_renderer = FrameRenderer.init(&frame_renderer_shared);

    var app_state = App.AppState.init(alloc);
    defer app_state.deinit();

    var save_data = App.Save.load(alloc, args.output);
    defer save_data.deinit();

    var clip_manager = try ClipManager.init(alloc, save_data.clips());
    defer clip_manager.deinit();

    const audio_player = try makeAudioPlayer(alloc, &dec);
    defer if (audio_player) |p| p.deinit();

    var wtm: ?WordTimestampGenerator = null;
    if (args.generate_subtitles) {
        wtm = try WordTimestampGenerator.init(alloc, args.input, save_data.wordTimestampMap());
    }
    defer if (wtm) |*w| w.deinit();

    var wtm_ptr: ?*WordTimestampGenerator = null;
    if (wtm) |*w| wtm_ptr = w;

    const gui = c.gui_init(&app_state);
    defer c.gui_free(gui);

    const app_refs: App.AppRefs = .{
        .alloc = alloc,
        .frame_renderer = &frame_renderer_shared,
        .gui = gui,
        .app_state = &app_state,
        .dec = &dec,
        .audio_player = audio_player,
        .clip_manager = &clip_manager,
        .wtm = wtm_ptr,
        .save_path = args.output,
    };

    const main_loop_thread = try std.Thread.spawn(.{}, main_loop, .{app_refs});
    c.gui_run(gui, &frame_renderer, &audio_renderer, wtm_ptr);
    main_loop_thread.join();
}
