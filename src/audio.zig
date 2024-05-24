const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;
const decoder = @import("decoder.zig");
const AudioFrame = decoder.AudioFrame;

pub const Format = enum {
    f32,

    pub fn sampleSize(self: Format) usize {
        switch (self) {
            .f32 => return 4,
        }
    }

    fn toMaFormat(self: Format) c.ma_format {
        switch (self) {
            .f32 => return c.ma_format_f32,
        }
    }
};

pub const AudioError = error{
    InvalidParams,
    DeviceInit,
    DeviceIo,
} || Allocator.Error;

const FrameQueue = struct {
    const Fifo = std.fifo.LinearFifo(AudioFrame, .{ .Static = 10 });
    inner: Fifo,
    frame_sample_idx: usize,
    channel_idx: usize,

    fn init() FrameQueue {
        return .{
            .inner = Fifo.init(),
            .frame_sample_idx = 0,
            .channel_idx = 0,
        };
    }

    fn deinit(self: *FrameQueue) void {
        while (true) {
            var item = self.inner.readItem() orelse {
                break;
            };
            item.deinit();
        }
        self.inner.deinit();
    }

    fn push(self: *FrameQueue, frame: AudioFrame) !void {
        try self.inner.writeItem(frame);
    }

    fn freeSpace(self: *const FrameQueue) usize {
        return self.inner.writableLength();
    }

    // Returns one sample for one channel. Each iteration will increment by
    // channel, then by sample
    fn next(self: *FrameQueue) ?[]const u8 {
        while (true) {
            if (self.inner.count == 0) {
                return null;
            }

            var frame = self.inner.peekItem(0);

            if (self.channel_idx >= frame.channel_data.items.len) {
                self.channel_idx = 0;
                self.frame_sample_idx += 1;
            }

            if (self.frame_sample_idx >= frame.num_samples) {
                var last_frame = self.inner.readItem();
                last_frame.?.deinit();
                self.frame_sample_idx = 0;
                continue;
            }

            const sample_size = frame.info.format.sampleSize();
            const sample_start = self.frame_sample_idx * sample_size;
            const sample_end = sample_start + sample_size;

            defer self.channel_idx += 1;
            return frame.channel_data.items[self.channel_idx][sample_start..sample_end];
        }
    }
};

pub const Player = struct {
    const ThreadData = struct {
        samples_provided: usize,
        frame_samples_used: usize,
    };

    const SharedData = struct {
        frame_queue_mutex: std.Thread.Mutex,
        frame_queue: FrameQueue,
    };

    alloc: Allocator,
    context: *c.ma_context,
    device: *c.ma_device,

    shared: SharedData,
    thread_priv: ThreadData,

    pub const InitParams = struct {
        channels: usize,
        format: Format,
        sample_rate: usize,
    };

    pub fn init(alloc: Allocator, params: InitParams) AudioError!*Player {
        const ret = try alloc.create(Player);
        errdefer alloc.destroy(ret);

        const context = try makeContext(alloc);
        errdefer deleteContext(alloc, context);

        const config = try makeDeviceConfig(params, ret);

        const device = try makeDevice(alloc, context, config);
        errdefer deleteDevice(alloc, device);

        const frame_queue = FrameQueue.init();

        ret.* = .{
            .alloc = alloc,
            .context = context,
            .device = device,
            .shared = .{
                .frame_queue_mutex = std.Thread.Mutex{},
                .frame_queue = frame_queue,
            },
            .thread_priv = .{
                .samples_provided = 0,
                .frame_samples_used = 0,
            },
        };

        return ret;
    }

    pub fn deinit(self: *Player) void {
        deleteDevice(self.alloc, self.device);
        deleteContext(self.alloc, self.context);
        self.shared.frame_queue.deinit();
        self.alloc.destroy(self);
    }

    pub fn start(self: *Player) !void {
        if (c.ma_device_start(self.device) != c.MA_SUCCESS) {
            std.log.err("Failed to start playback", .{});
            return AudioError.DeviceIo;
        }
    }

    pub fn stop(self: *Player) !void {
        if (c.ma_device_stop(self.device) != c.MA_SUCCESS) {
            std.log.err("Failed to stop playback", .{});
            return AudioError.DeviceIo;
        }
    }

    pub fn numFramesNeeded(self: *Player) usize {
        self.shared.frame_queue_mutex.lock();
        defer self.shared.frame_queue_mutex.unlock();

        return self.shared.frame_queue.freeSpace();
    }

    pub fn pushFrame(self: *Player, frame: AudioFrame) !void {
        self.shared.frame_queue_mutex.lock();
        defer self.shared.frame_queue_mutex.unlock();

        try self.shared.frame_queue.push(frame);
    }

    fn callback(device_v: ?*anyopaque, output_v: ?*anyopaque, input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.C) void {
        _ = input;

        const device: *c.ma_device = @ptrCast(@alignCast(device_v));
        const self: *Player = @ptrCast(@alignCast(device.pUserData));

        const output: [*]u8 = @ptrCast(output_v);
        var output_pos: usize = 0;

        const sample_size = maSampleSize(device.playback.format);

        self.shared.frame_queue_mutex.lock();
        defer self.shared.frame_queue_mutex.unlock();

        while (output_pos < frame_count * device.playback.channels * sample_size) {
            const sample = self.shared.frame_queue.next() orelse {
                return;
            };
            const output_start = output_pos;
            const output_end = output_start + sample.len;
            @memcpy(output[output_start..output_end], sample);
            output_pos = output_end;
        }
    }

    fn makeContext(alloc: Allocator) AudioError!*c.ma_context {
        const context = try alloc.create(c.ma_context);
        errdefer alloc.destroy(context);

        if (c.ma_context_init(null, 0, null, @ptrCast(context)) != c.MA_SUCCESS) {
            std.log.err("Failed to initialize context", .{});
            return AudioError.DeviceInit;
        }

        return context;
    }

    fn deleteContext(alloc: Allocator, context: *c.ma_context) void {
        _ = c.ma_context_uninit(@ptrCast(context));
        alloc.destroy(context);
    }

    fn makeDeviceConfig(params: InitParams, player: *Player) AudioError!c.ma_device_config {
        var config = c.ma_device_config_init(c.ma_device_type_playback);
        config.playback.format = params.format.toMaFormat();
        config.playback.channels = std.math.cast(c_uint, params.channels) orelse {
            std.log.err("num channels value can not be converted to backend format", .{});
            return AudioError.InvalidParams;
        };
        config.sampleRate = std.math.cast(c_uint, params.sample_rate) orelse {
            std.log.err("sample_rate value can not be converted to backend format", .{});
            return AudioError.InvalidParams;
        };
        config.periodSizeInFrames = 900;
        config.pUserData = player;
        config.dataCallback = Player.callback;
        return config;
    }

    fn makeDevice(alloc: Allocator, context: *c.ma_context, config: c.ma_device_config) AudioError!*c.ma_device {
        const device = try alloc.create(c.ma_device);
        errdefer alloc.destroy(device);

        if (c.ma_device_init(context, &config, device) != c.MA_SUCCESS) {
            std.log.err("Failed to init device", .{});
            return AudioError.DeviceInit;
        }

        return device;
    }

    fn deleteDevice(alloc: Allocator, device: *c.ma_device) void {
        c.ma_device_uninit(device);
        alloc.destroy(device);
    }
};

fn maSampleSize(format: c.ma_format) usize {
    switch (format) {
        c.ma_format_f32 => return 4,
        else => {
            std.debug.panic("Unknown format: {d}", .{format});
        },
    }
}
