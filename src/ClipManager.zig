const std = @import("std");
const c = @import("c.zig");
const decoder = @import("decoder.zig");
const save = @import("save.zig");
const VideoDecoder = decoder.VideoDecoder;

const Allocator = std.mem.Allocator;

const ClipList = std.ArrayList(c.Clip);

clips: ClipList,
clip_id: usize,

const ClipManager = @This();

fn maxClipId(clips: []const c.Clip) usize {
    var ret: usize = 0;

    for (clips) |clip| {
        ret = @max(clip.id, ret);
    }

    return ret;
}

pub fn init(alloc: Allocator, init_data: ?save.Data.Field) !ClipManager {
    var clips = ClipList.init(alloc);
    if (init_data) |id| {
        const loaded = try id.as([]const c.Clip);
        defer loaded.deinit();

        try clips.appendSlice(loaded.value);
    }

    const clip_id = maxClipId(clips.items) + 1;

    return .{
        .clips = clips,
        .clip_id = clip_id,
    };
}

pub fn deinit(self: *ClipManager) void {
    self.clips.deinit();
}

pub fn serialize(self: *ClipManager, writer: anytype) !void {
    const lessThanWithContext = struct {
        fn f(_: void, lhs: c.Clip, rhs: c.Clip) bool {
            return lessThan(lhs, rhs);
        }
    }.f;

    std.mem.sort(c.Clip, self.clips.items, {}, lessThanWithContext);
    try writer.write(self.clips.items);
}

fn writeClip(clip: c.Clip, output: anytype) !void {
    try output.beginObject();

    try output.objectField("id");
    try output.write(clip.id);

    try output.objectField("start");
    try output.write(clip.start);

    try output.objectField("end");
    try output.write(clip.end);

    try output.endObject();
}

pub fn update(self: *ClipManager, clip: c.Clip) void {
    if (self.findClipIdx(clip.id)) |i| {
        self.clips.items[i].start = @min(clip.start, clip.end);
        self.clips.items[i].end = @max(clip.start, clip.end);
    }
}

pub fn add(self: *ClipManager, clip_in: c.Clip) !void {
    defer self.clip_id += 1;
    var clip = clip_in;
    clip.id = self.clip_id;
    if (clip.start > clip.end) {
        std.mem.swap(f32, &clip.start, &clip.end);
    }
    try self.clips.append(clip);
}

pub fn remove(self: *ClipManager, id: usize) void {
    if (self.findClipIdx(id)) |i| {
        _ = self.clips.swapRemove(i);
    }
}

pub fn clipForPts(self: *ClipManager, pts: f32) ?c.Clip {
    for (self.clips.items) |clip| {
        if (pts >= clip.start and pts <= clip.end) {
            return clip;
        }
    }

    return null;
}

pub fn nextClip(self: *ClipManager, clip_id: usize) ?c.Clip {
    const clip_idx = self.findClipIdx(clip_id) orelse {
        return null;
    };

    const clip = self.clips.items[clip_idx];
    var next_clip: ?c.Clip = null;
    for (self.clips.items) |item| {
        if (item.id == clip.id) {
            continue;
        }

        if (lessThan(item, clip)) {
            continue;
        }

        if (next_clip == null) {
            next_clip = item;
            continue;
        }

        if (lessThan(item, next_clip.?)) {
            next_clip = item;
        }
    }
    return next_clip;
}

fn firstClip(self: *ClipManager) ?c.Clip {
    if (self.clips.items.len == 0) {
        return null;
    }

    var ret = self.clips.items[0];
    for (1..self.clips.items.len) |i| {
        const clip = self.clips.items[i];
        if (lessThan(clip, ret)) {
            ret = clip;
        }
    }
    return ret;
}

fn lessThan(a: c.Clip, b: c.Clip) bool {
    if (a.start != b.start) {
        return a.start < b.start;
    }

    if (a.end != b.end) {
        return a.end < b.end;
    }

    return a.id < b.id;
}

fn findClipIdx(self: *ClipManager, id: usize) ?usize {
    var item_idx: ?usize = null;
    for (0..self.clips.items.len) |i| {
        if (self.clips.items[i].id == id) {
            item_idx = i;
            break;
        }
    }

    return item_idx;
}
