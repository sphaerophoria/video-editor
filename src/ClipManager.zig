const std = @import("std");
const c = @import("c.zig");
const decoder = @import("decoder.zig");
const VideoDecoder = decoder.VideoDecoder;

const Allocator = std.mem.Allocator;

const ClipList = std.ArrayList(c.Clip);

clips: ClipList,
clip_id: usize,
save_path: []const u8,

const ClipManager = @This();

pub fn init(alloc: Allocator, save_path: []const u8) !ClipManager {
    var clips = ClipList.init(alloc);
    errdefer clips.deinit();

    // Ensure writeable before any work is done
    const f = try std.fs.cwd().createFile(save_path, .{});
    f.close();

    return .{
        .clips = clips,
        .clip_id = 0,
        .save_path = save_path,
    };
}

pub fn deinit(self: *ClipManager) void {
    self.clips.deinit();
}

pub fn save(self: *ClipManager) !void {
    const f = try std.fs.cwd().createFile(self.save_path, .{});
    defer f.close();

    var output = std.json.writeStream(f.writer(), .{
        .whitespace = .indent_2,
    });

    try output.beginArray();
    var clip = self.firstClip() orelse {
        try output.endArray();
        return;
    };

    try writeClip(clip, &output);
    while (self.nextClip(clip.id)) |next_clip| {
        clip = next_clip;
        try writeClip(clip, &output);
    }

    try output.endArray();
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
