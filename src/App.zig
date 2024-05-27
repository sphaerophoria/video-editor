const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const ClipManager = @import("ClipManager.zig");
const FrameRenderer = @import("FrameRenderer.zig");
const decoder = @import("decoder.zig");
const audio = @import("audio.zig");
const save_mod = @import("save.zig");
const WordTimestampGenerator = @import("WordTimestampGenerator.zig");

pub const AppRefs = struct {
    alloc: Allocator,
    frame_renderer: *FrameRenderer.SharedData,
    gui: ?*c.Gui,
    app_state: *AppState,
    dec: *decoder.VideoDecoder,
    audio_player: ?*audio.Player,
    clip_manager: *ClipManager,
    wtm: ?*WordTimestampGenerator,
    save_path: []const u8,
};

const App = @This();
refs: AppRefs,

player_state: PlayerState,
last_pts: f32,
stream_id: usize,

pub fn init(refs: AppRefs) !App {
    const img = try getNextVideoFrame(refs.dec, refs.audio_player, null) orelse {
        std.log.err("Video should have at least one frame", .{});
        return error.InvalidData;
    };
    refs.frame_renderer.swapFrame(img);

    // Open as write to ensure that we have write permissions for later
    const f = try std.fs.cwd().createFile(refs.save_path, .{
        .read = true,
        .truncate = false,
    });
    defer f.close();

    return .{
        .refs = refs,
        .player_state = PlayerState.init(try std.time.Instant.now()),
        .stream_id = img.stream_id,
        .last_pts = img.pts,
    };
}

pub fn run(self: *App) !void {
    if (self.refs.audio_player) |p| try p.start();

    while (true) {
        var now = try std.time.Instant.now();

        if (try self.applyGuiActions(&now)) {
            break;
        }
        try self.updateVideoFrame(&now);
        try self.updateAppState();
        try self.sleepUntilNextFrame();
    }
}

fn applyGuiActions(self: *App, now: *std.time.Instant) !bool {
    var seek_position: ?f32 = null;
    while (true) {
        const action = c.gui_next_action(self.refs.gui);
        switch (action.tag) {
            c.gui_action_toggle_pause => {
                self.player_state.togglePause(now.*);
                c.gui_notify_update(self.refs.gui);
            },
            c.gui_action_none => {
                break;
            },
            c.gui_action_close => {
                return true;
            },
            c.gui_action_seek => {
                seek_position = action.data.seek_position;
                c.gui_notify_update(self.refs.gui);
            },
            c.gui_action_clip_edit => {
                self.refs.clip_manager.update(action.data.clip);
                c.gui_notify_update(self.refs.gui);
            },
            c.gui_action_clip_remove => {
                const clip = self.refs.clip_manager.clipForPts(action.data.seek_position);
                if (clip) |cl| {
                    self.refs.clip_manager.remove(cl.id);
                }
            },
            c.gui_action_clip_add => {
                try self.refs.clip_manager.add(action.data.clip);
                c.gui_notify_update(self.refs.gui);
            },
            c.gui_action_save => {
                try Save.save(self.refs);
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

fn setEndOfVideo(self: *App, now: std.time.Instant) void {
    self.player_state.pause(now);
    self.last_pts = self.refs.dec.duration;
    c.gui_notify_update(self.refs.gui);
}

fn seekToPts(self: *App, now: *std.time.Instant, pts: f32) !void {
    try self.refs.dec.seek(pts, self.stream_id);

    var img = try getNextVideoFrame(self.refs.dec, null, self.stream_id) orelse {
        self.setEndOfVideo(now.*);
        return;
    };

    self.last_pts = img.pts;

    while (true) {
        const new_img = try getNextVideoFrame(self.refs.dec, null, self.stream_id) orelse {
            self.setEndOfVideo(now.*);
            break;
        };
        img.deinit();
        img = new_img;

        //std.debug.print("set last pts to {d}\n", .{new_img.pts});
        self.last_pts = new_img.pts;

        if (self.last_pts >= pts) {
            break;
        }
    }

    now.* = try std.time.Instant.now();
    self.player_state.seek(now.*, self.last_pts);
    self.refs.frame_renderer.swapFrame(img);
    c.gui_notify_update(self.refs.gui);
}

fn updateVideoFrame(self: *App, now: *std.time.Instant) !void {
    const clip_for_pts = self.refs.clip_manager.clipForPts(self.last_pts);

    while (self.player_state.shouldUpdateFrame(now.*, self.last_pts)) {
        var new_img = try getNextVideoFrame(self.refs.dec, self.refs.audio_player, self.stream_id) orelse {
            self.setEndOfVideo(now.*);
            break;
        };

        if (clip_for_pts) |cl| {
            if (new_img.pts > cl.end) {
                defer new_img.deinit();

                if (self.refs.clip_manager.nextClip(cl.id)) |next_clip| {
                    try self.seekToPts(now, next_clip.start);
                } else {
                    self.player_state.pause(now.*);
                }

                c.gui_notify_update(self.refs.gui);
                break;
            }
        }

        self.last_pts = new_img.pts;
        self.refs.frame_renderer.swapFrame(new_img);
        c.gui_notify_update(self.refs.gui);
    }
}

fn updateAppState(self: *App) !void {
    if (self.refs.wtm) |wtm| wtm.shared.mutex.lock();
    defer {
        if (self.refs.wtm) |wtm| wtm.shared.mutex.unlock();
    }

    var text: []const u8 = &.{};
    if (self.refs.wtm) |wtm| text = wtm.shared.text.items;

    var text_split_indices: []const u64 = &.{};
    if (self.refs.wtm) |wtm| text_split_indices = wtm.shared.split_indices.items;

    try self.refs.app_state.setSnapshot(.{
        .paused = self.player_state.isPaused(),
        .current_position = self.last_pts,
        .total_runtime = self.refs.dec.duration,
        .clips = self.refs.clip_manager.clips.items,
        .text = text,
        .text_split_indices = text_split_indices,
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
    alloc: Allocator,
    snapshot: Snapshot,

    const Snapshot = struct {
        paused: bool,
        current_position: f32,
        total_runtime: f32,
        clips: []const c.Clip,
        text: []const u8,
        text_split_indices: []const u64,

        fn clone(self: *const @This(), alloc: Allocator) !Snapshot {
            const new_clips = try alloc.dupe(c.Clip, self.clips);
            errdefer alloc.free(new_clips);

            const new_text = try alloc.dupe(u8, self.text);
            errdefer alloc.free(new_text);

            const text_split_indices = try alloc.dupe(u64, self.text_split_indices);
            errdefer alloc.free(text_split_indices);

            var ret = self.*;
            ret.clips = new_clips;
            ret.text = new_text;
            ret.text_split_indices = text_split_indices;
            return ret;
        }

        fn toCRepr(self: *@This()) c.AppStateSnapshot {
            return .{
                .paused = self.paused,
                .current_position = self.current_position,
                .total_runtime = self.total_runtime,
                .clips = self.clips.ptr,
                .num_clips = self.clips.len,
                .text = self.text.ptr,
                .text_len = self.text.len,
                .text_split_indices = self.text_split_indices.ptr,
                .text_split_indices_len = self.text_split_indices.len,
            };
        }

        fn fromCRepr(c_repr: c.AppStateSnapshot) Snapshot {
            return .{
                .paused = c_repr.paused,
                .current_position = c_repr.current_position,
                .total_runtime = c_repr.total_runtime,
                .clips = c_repr.clips[0..c_repr.num_clips],
                .text = c_repr.text[0..c_repr.text_len],
                .text_split_indices = c_repr.text_split_indices[0..c_repr.text_split_indices_len],
            };
        }

        fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.clips);
            alloc.free(self.text);
            alloc.free(self.text_split_indices);
        }
    };

    pub fn init(alloc: Allocator) AppState {
        return .{
            .mutex = .{},
            .alloc = alloc,
            .snapshot = .{
                .paused = false,
                .current_position = 0.0,
                .total_runtime = 0.0,
                .clips = &.{},
                .text = &.{},
                .text_split_indices = &.{},
            },
        };
    }

    pub fn setSnapshot(self: *AppState, snapshot: Snapshot) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const new_snapshot = try snapshot.clone(self.alloc);
        self.snapshot.deinit(self.alloc);
        self.snapshot = new_snapshot;
    }

    pub fn deinit(self: *AppState) void {
        self.snapshot.deinit(self.alloc);
    }
};

pub export fn appstate_snapshot(state: *AppState) c.AppStateSnapshot {
    state.mutex.lock();
    defer state.mutex.unlock();

    var output_snapshot = state.snapshot.clone(state.alloc) catch {
        std.debug.panic("Failed to snapshot app state", .{});
    };

    return output_snapshot.toCRepr();
}

pub export fn appstate_deinit(state: *AppState, c_repr: *const c.AppStateSnapshot) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var snapshot = AppState.Snapshot.fromCRepr(c_repr.*);
    snapshot.deinit(state.alloc);
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

fn getNextVideoFrame(dec: *decoder.VideoDecoder, audio_player: ?*audio.Player, stream_id: ?usize) !?decoder.VideoFrame {
    while (true) {
        var frame = try dec.next(null);
        if (frame == null) {
            return null;
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

pub const Save = struct {
    data: ?save_mod.Data,

    const clip_key = "clips";
    const wtm_key = "script_generator";

    pub fn load(alloc: Allocator, path: []const u8) Save {
        if (save_mod.Data.load(alloc, path)) |sd| {
            return .{
                .data = sd,
            };
        } else |e| {
            std.log.err("Failed to load save: {any}", .{e});
            return .{
                .data = null,
            };
        }
    }

    pub fn deinit(self: *const Save) void {
        if (self.data) |sd| sd.deinit();
    }
    pub fn clips(self: *Save) ?save_mod.Data.Field {
        return self.getField(clip_key);
    }

    pub fn wordTimestampMap(self: *Save) ?save_mod.Data.Field {
        return self.getField(wtm_key);
    }

    fn getField(self: *Save, key: []const u8) ?save_mod.Data.Field {
        if (self.data == null) {
            return null;
        }

        return self.data.?.field(key);
    }

    fn save(refs: AppRefs) !void {
        var save_writer = try save_mod.Writer.init(refs.save_path);

        try refs.clip_manager.serialize(try save_writer.field(clip_key));

        const wtm_field = try save_writer.field(wtm_key);
        if (refs.wtm) |wtm| {
            try wtm.serialize(wtm_field);
        } else {
            try wtm_field.write(null);
        }

        try save_writer.finish();
    }
};
