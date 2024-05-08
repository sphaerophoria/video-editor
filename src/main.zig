const std = @import("std");
const c = @import("c.zig");
const Gui = @import("Gui.zig");
const decoder = @import("decoder.zig");

const PlayerState = struct {
    start_time: std.time.Instant,
    pause_time: ?std.time.Instant,
    time_adjustment: u64,

    fn init(now: std.time.Instant) PlayerState {
        return .{
            .start_time = now,
            .pause_time = null,
            .time_adjustment = 0,
        };
    }

    fn pause(self: *PlayerState, now: std.time.Instant) void {
        // Do not overwrite existing pause start
        if (self.isPaused()) {
            return;
        }
        self.pause_time = now;
    }

    fn play(self: *PlayerState, now: std.time.Instant) void {
        // Avoid invalid access to pause_time below
        if (self.pause_time == null) {
            return;
        }

        self.time_adjustment += now.since(self.pause_time.?);
        self.pause_time = null;
    }

    fn isPaused(self: *const PlayerState) bool {
        return self.pause_time != null;
    }

    fn togglePause(self: *PlayerState, now: std.time.Instant) void {
        if (self.isPaused()) {
            self.play(now);
        } else {
            self.pause(now);
        }
    }

    fn shouldUpdateFrame(self: *const PlayerState, now: std.time.Instant, frame_pts: f32) bool {
        return self.pause_time == null and frame_pts * 1e9 < @as(f32, @floatFromInt(now.since(self.start_time) - self.time_adjustment));
    }
};

const ArgParseError = std.process.ArgIterator.InitError;

const Args = struct {
    it: std.process.ArgIterator,
    input: [:0]const u8,
    lint: bool,

    const Switch = enum {
        @"--input",
        @"--lint",
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

        var lint = false;
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
                .@"--lint" => {
                    lint = true;
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
            .lint = lint,
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
                .@"--lint" => {
                    print("Optional, if passed will set params to make linting easier", .{});
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.init(alloc);
    defer args.deinit();

    var gui = try Gui.init();
    defer gui.deinit();

    var dec = try decoder.VideoDecoder.init(args.input);
    defer dec.deinit();

    var img = try dec.next();

    var player_state = PlayerState.init(try std.time.Instant.now());

    var i: usize = 0;
    while (!gui.shouldClose()) {
        defer i += 1;
        const now = try std.time.Instant.now();

        var actions = gui.getActions(alloc);
        defer actions.deinit();

        for (actions.items) |action| {
            switch (action) {
                .toggle_pause => {
                    player_state.togglePause(now);
                },
            }
        }

        while (player_state.shouldUpdateFrame(now, img.pts)) {
            gui.swapFrame(img);
            img = try dec.next();
            if (args.lint) {
                break;
            }
        }

        gui.render();

        if (args.lint and i > 20) {
            gui.setClose();
        }
    }
}
