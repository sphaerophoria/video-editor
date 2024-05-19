const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const FrameRenderer = @import("FrameRenderer.zig");
const decoder = @import("decoder.zig");
const audio = @import("audio.zig");

pub const AppRefs = struct {
    alloc: Allocator,
    frame_renderer: *FrameRenderer.SharedData,
    gui: ?*c.Gui,
    app_state: *AppState,
    dec: *decoder.VideoDecoder,
    audio_player: ?*audio.Player,
};

const App = @This();
refs: AppRefs,

player_state: PlayerState,
last_pts: f32,
stream_id: usize,
total_runtime: f32,

pub fn init(refs: AppRefs) !App {
    const img = try getNextVideoFrame(refs.dec, refs.audio_player, null);
    refs.frame_renderer.swapFrame(img);

    return .{
        .refs = refs,
        .player_state = PlayerState.init(try std.time.Instant.now()),
        .stream_id = img.stream_id,
        .last_pts = img.pts,
        .total_runtime = refs.dec.duration(),
    };
}

pub fn run(self: *App) !void {
    if (self.refs.audio_player) |p| try p.start();

    while (true) {
        const now = try std.time.Instant.now();

        if (try self.applyGuiActions(now)) {
            break;
        }
        try self.updateVideoFrame(now);
        self.updateAppState();
        try self.sleepUntilNextFrame();
    }
}

fn applyGuiActions(self: *App, now: std.time.Instant) !bool {
    var seek_position: ?f32 = null;
    while (true) {
        const action = c.gui_next_action(self.refs.gui);
        switch (action.tag) {
            c.gui_action_toggle_pause => {
                self.player_state.togglePause(now);
                c.gui_notify_update(self.refs.gui);
            },
            c.gui_action_none => {
                break;
            },
            c.gui_action_close => {
                return true;
            },
            c.gui_action_seek => {
                seek_position = action.seek_position;
            },
            else => {
                std.debug.panic("invalid action: {d}", .{action.tag});
            },
        }
    }

    if (seek_position) |s| {
        try self.seekToPts(now, s);
    }

    return false;
}

fn seekToPts(self: *App, now: std.time.Instant, pts: f32) !void {
    try self.refs.dec.seek(pts, self.stream_id);
    var new_img: decoder.VideoFrame = undefined;
    while (true) {
        new_img = try getNextVideoFrame(self.refs.dec, null, self.stream_id);
        self.last_pts = new_img.pts;

        if (self.last_pts >= pts) {
            break;
        }
    }
    self.player_state.seek(now, self.last_pts);
    self.refs.frame_renderer.swapFrame(new_img);
    c.gui_notify_update(self.refs.gui);
}

fn updateVideoFrame(self: *App, now: std.time.Instant) !void {
    while (self.player_state.shouldUpdateFrame(now, self.last_pts)) {
        const new_img = try getNextVideoFrame(self.refs.dec, self.refs.audio_player, self.stream_id);
        self.last_pts = new_img.pts;
        self.refs.frame_renderer.swapFrame(new_img);
        c.gui_notify_update(self.refs.gui);
    }
}

fn updateAppState(self: *App) void {
    self.refs.app_state.setSnapshot(.{
        .paused = self.player_state.isPaused(),
        .current_position = self.last_pts,
        .total_runtime = self.total_runtime,
    });
}

fn sleepUntilNextFrame(self: *App) !void {
    const now = try std.time.Instant.now();
    const ns_until_next_frame = self.player_state.nsUntilNextFrame(now, self.last_pts) orelse {
        // Wait some arbitrary amount of time before processing UI inputs again
        std.time.sleep(10_000_000);
        return;
    };

    if (ns_until_next_frame > 0) {
        const sleep_time: u64 = @intCast(ns_until_next_frame);
        std.time.sleep(sleep_time);
    }
}

pub const AppState = struct {
    mutex: std.Thread.Mutex,
    inner: c.AppStateSnapshot,

    pub fn init() AppState {
        return .{
            .mutex = .{},
            .inner = .{
                .paused = false,
                .current_position = 0.0,
                .total_runtime = 0.0,
            },
        };
    }

    pub fn setSnapshot(self: *AppState, snapshot: c.AppStateSnapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.inner = snapshot;
    }
};

pub export fn appstate_snapshot(state: *AppState) c.AppStateSnapshot {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.inner;
}

const PlayerState = struct {
    start_time: std.time.Instant,
    pause_time: ?std.time.Instant,
    time_adjustment_ns: i64,

    fn init(now: std.time.Instant) PlayerState {
        return .{
            .start_time = now,
            .pause_time = null,
            .time_adjustment_ns = 0,
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

        self.time_adjustment_ns += @intCast(now.since(self.pause_time.?));
        self.pause_time = null;
    }

    fn seek(self: *PlayerState, now: std.time.Instant, pts: f32) void {
        self.start_time = now;
        const seek_pos_ns: i64 = @intFromFloat(pts * 1e9);
        self.time_adjustment_ns = -seek_pos_ns;
        if (self.pause_time) |_| {
            self.pause_time = now;
        }
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
        const time_till_next_ns = self.nsUntilNextFrame(now, frame_pts) orelse {
            return false;
        };
        return time_till_next_ns < 0;
    }

    fn nsUntilNextFrame(self: *const PlayerState, now: std.time.Instant, frame_pts: f32) ?i64 {
        if (self.pause_time != null) {
            return null;
        }

        const time_since_start_ns: i64 = @intCast(now.since(self.start_time));
        const time_since_start_adjusted: i64 = time_since_start_ns - self.time_adjustment_ns;
        const frame_pts_ns: i64 = @intFromFloat(frame_pts * 1e9);
        return frame_pts_ns - time_since_start_adjusted;
    }
};

fn getNextVideoFrame(dec: *decoder.VideoDecoder, audio_player: ?*audio.Player, stream_id: ?usize) !decoder.VideoFrame {
    while (true) {
        var frame = try dec.next();
        if (frame == null) {
            continue;
        }

        switch (frame.?) {
            .audio => |*af| {
                if (audio_player) |p| {
                    p.pushFrame(af.*) catch {
                        std.log.err("Audio thread falling behind, dropping frame", .{});
                        af.deinit();
                    };
                } else {
                    af.deinit();
                }
            },
            .video => |*vf| {
                if (stream_id == null) {
                    return vf.*;
                }

                if (stream_id != vf.stream_id) {
                    std.log.warn("Ignoring frame from new video stream", .{});
                    vf.deinit();
                    continue;
                }
                return vf.*;
            },
        }
    }
}
