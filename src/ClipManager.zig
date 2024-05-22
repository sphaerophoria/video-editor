const std = @import("std");
const c = @import("c.zig");
const decoder = @import("decoder.zig");
const VideoDecoder = decoder.VideoDecoder;

const Allocator = std.mem.Allocator;

const ClipList = std.ArrayList(c.Clip);

clips: ClipList,
clip_id: usize,

const ClipManager = @This();

pub fn init(alloc: Allocator) !ClipManager {
    var clips = ClipList.init(alloc);
    errdefer clips.deinit();

    return .{
        .clips = clips,
        .clip_id = 0,
    };
}

pub fn deinit(self: *ClipManager) void {
    self.clips.deinit();
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
