const c = @import("c.zig");
const decoder = @import("decoder.zig");
const std = @import("std");
const audio = @import("audio.zig");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const SegmentBounds = struct {
    char_start: usize,
    char_end: usize,
    start: f32,
    end: f32,
};

alloc: Allocator,
init_thread: Thread,
shared: *Shared,

const Shared = struct {
    mutex: Mutex,
    segments: std.ArrayList(SegmentBounds),
    text: std.ArrayList(u8),

    // No mutex lock necessary
    shutdown: std.atomic.Value(bool),

    fn deinit(self: *Shared) void {
        self.segments.deinit();
        self.text.deinit();
    }
};

const Whisper = @This();

fn logCallback(level: c_uint, s: [*c]const u8, userdata: ?*anyopaque) callconv(.C) void {
    _ = level;
    _ = s;
    _ = userdata;
}

// FIXME: dedup with audio renderer
fn findFirstAudioStream(dec: *decoder.VideoDecoder) !?decoder.AudioStreamInfo {
    var stream_it = dec.streams();
    while (try stream_it.next()) |stream| {
        switch (stream) {
            .audio => |as| {
                if (as.format == audio.Format.f32) {
                    return as;
                }
            },
            else => continue,
        }
    }

    return null;
}

const whisper_sample_rate = 16000;
const WhisperInputResampler = struct {
    stream: decoder.AudioStreamInfo,
    dec: *decoder.VideoDecoder,
    frame: decoder.AudioFrame,
    frame_start: usize,
    output_samples: usize,
    multiplier: f32,

    fn init(dec: *decoder.VideoDecoder) !WhisperInputResampler {
        const stream = try findFirstAudioStream(dec) orelse {
            return error.NoAudio;
        };
        std.debug.assert(stream.format == audio.Format.f32);

        const frame = try dec.next(stream.stream_id) orelse {
            return error.NoAudio;
        };

        var multiplier: f32 = @floatFromInt(stream.sample_rate);
        multiplier /= whisper_sample_rate;
        return .{
            .stream = stream,
            .dec = dec,
            .frame = frame.audio,
            .frame_start = 0,
            .output_samples = 0,
            .multiplier = multiplier,
        };
    }

    fn deinit(self: *WhisperInputResampler) void {
        self.frame.deinit();
    }

    // Returns the next sample at the requested rate
    fn next(self: *WhisperInputResampler) !?[]const u8 {
        while (true) {
            const input_idx = @as(f32, @floatFromInt(self.output_samples)) * self.multiplier;
            const frame_idx = @as(usize, @intFromFloat(input_idx)) - self.frame_start;

            if (frame_idx >= self.frame.num_samples) {
                const frame = try self.dec.next(self.stream.stream_id) orelse {
                    return null;
                };
                self.frame_start += self.frame.num_samples;
                self.frame.deinit();
                self.frame = frame.audio;
                continue;
            }

            const start = frame_idx * self.frame.info.format.sampleSize();
            const end = start + self.frame.info.format.sampleSize();
            defer self.output_samples += 1;
            return self.frame.channel_data.items[0][start..end];
        }
    }
};

const WhisperRunner = struct {
    ctx: *c.whisper_context,
    params: c.whisper_full_params,
    start_time_ms: i64,
    const bytes_per_sample = 4;

    const SegmentIt = struct {
        ctx: *c.whisper_context,
        i: c_int,
        start_time_cs: i64,
        n_segments: usize,

        const Output = struct {
            text: []const u8,
            start_s: f32,
            end_s: f32,
        };

        fn next(self: *@This()) ?Output {
            if (self.i >= self.n_segments) {
                return null;
            }
            defer self.i += 1;

            const s = c.whisper_full_get_segment_text(self.ctx, self.i);
            const s_len = std.mem.len(s);
            const segment_start_cs = c.whisper_full_get_segment_t0(self.ctx, self.i) + self.start_time_cs;
            const segment_end_cs = c.whisper_full_get_segment_t1(self.ctx, self.i) + self.start_time_cs;
            var segment_start_s: f32 = @floatFromInt(segment_start_cs);
            segment_start_s /= 100;
            var segment_end_s: f32 = @floatFromInt(segment_end_cs);
            segment_end_s /= 100;

            return .{
                .start_s = segment_start_s,
                .end_s = segment_end_s,
                .text = s[0..s_len],
            };
        }
    };

    fn abortCallback(userdata: ?*anyopaque) callconv(.C) bool {
        const val: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata));
        return val.load(std.builtin.AtomicOrder.unordered);
    }

    fn init(shutdown: *std.atomic.Value(bool)) !WhisperRunner {
        c.whisper_log_set(logCallback, null);

        const cparams = c.whisper_context_default_params();
        const model: []const u8 = @embedFile("WordTimestampGenerator/ggml-tiny.en-q5_1.bin");
        const ctx = c.whisper_init_from_buffer_with_params(@constCast(model.ptr), model.len, cparams) orelse {
            std.log.err("Failed to create whisper context", .{});
            return error.Whisper;
        };

        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_BEAM_SEARCH);
        params.max_len = 1;
        params.token_timestamps = true;
        params.abort_callback = abortCallback;
        params.abort_callback_user_data = shutdown;

        return .{
            .start_time_ms = 0,
            .ctx = ctx,
            .params = params,
        };
    }

    fn deinit(self: *WhisperRunner) void {
        c.whisper_free(self.ctx);
    }

    fn next(self: *WhisperRunner, audio_buf: []const u8) !SegmentIt {
        const whisper_ret = c.whisper_full(self.ctx, self.params, @ptrCast(@alignCast(audio_buf.ptr)), @intCast(audio_buf.len / bytes_per_sample));
        if (whisper_ret != 0) {
            return error.Whisper;
        }

        const n_segments: usize = @intCast(c.whisper_full_n_segments(self.ctx));
        defer self.start_time_ms += @intCast(audio_buf.len * 1000 / whisper_sample_rate / bytes_per_sample);
        return .{
            .ctx = self.ctx,
            .i = 0,
            .start_time_cs = @divTrunc(self.start_time_ms, 10),
            .n_segments = n_segments,
        };
    }
};

fn initThread(alloc: Allocator, path: [:0]const u8, shared: *Shared) !void {
    var dec = try decoder.VideoDecoder.init(alloc, path);
    defer dec.deinit();

    var sampler = try WhisperInputResampler.init(&dec);
    defer sampler.deinit();

    c.whisper_log_set(logCallback, null);

    const sample_size = sampler.stream.format.sampleSize();
    const buf_size_s = 8;
    var audio_buf = try alloc.alloc(u8, 16000 * buf_size_s * sample_size);
    defer alloc.free(audio_buf);

    var buf_pos: usize = 0;

    var whisper = try WhisperRunner.init(&shared.shutdown);
    defer whisper.deinit();

    while (!shared.shutdown.load(std.builtin.AtomicOrder.unordered)) {
        const data = try sampler.next() orelse {
            break;
        };
        @memcpy(audio_buf[buf_pos .. buf_pos + data.len], data);
        buf_pos += data.len;

        if (buf_pos == audio_buf.len) {
            var samples = whisper.next(audio_buf) catch |e| {
                if (shared.shutdown.load(std.builtin.AtomicOrder.unordered)) {
                    return;
                }
                return e;
            };

            shared.mutex.lock();
            defer shared.mutex.unlock();

            while (samples.next()) |sample| {
                const segment = SegmentBounds{
                    .start = sample.start_s,
                    .end = sample.end_s,
                    .char_start = shared.text.items.len,
                    .char_end = shared.text.items.len + sample.text.len,
                };

                try shared.segments.append(segment);
                try shared.text.appendSlice(sample.text);
            }

            buf_pos = 0;
        }
    }

    var samples = try whisper.next(audio_buf[0..buf_pos]);

    shared.mutex.lock();
    defer shared.mutex.unlock();

    while (samples.next()) |sample| {
        const segment = SegmentBounds{
            .start = sample.start_s,
            .end = sample.end_s,
            .char_start = shared.text.items.len,
            .char_end = shared.text.items.len + sample.text.len,
        };

        try shared.segments.append(segment);
        try shared.text.appendSlice(sample.text);
    }
}

pub fn init(alloc: Allocator, path: [:0]const u8) !Whisper {
    var segments = std.ArrayList(SegmentBounds).init(alloc);
    errdefer segments.deinit();

    var text = std.ArrayList(u8).init(alloc);
    errdefer text.deinit();

    const shared = try alloc.create(Shared);
    errdefer alloc.destroy(shared);

    shared.* = .{
        .mutex = .{},
        .segments = segments,
        .text = text,
        .shutdown = std.atomic.Value(bool).init(false),
    };

    const init_thread = try Thread.spawn(.{}, initThread, .{ alloc, path, shared });

    return .{
        .alloc = alloc,
        .init_thread = init_thread,
        .shared = shared,
    };
}

pub fn deinit(self: *Whisper) void {
    self.shared.shutdown.store(true, std.builtin.AtomicOrder.unordered);
    self.init_thread.join();
    self.shared.deinit();
    self.alloc.destroy(self.shared);
}

pub export fn wtm_get_time(m: *Whisper, char_pos: u64) f32 {
    const lessThan = struct {
        fn f(_: void, lhs: u64, rhs: SegmentBounds) bool {
            return lhs < rhs.char_start;
        }
    }.f;

    m.shared.mutex.lock();
    defer m.shared.mutex.unlock();

    const elem = std.sort.upperBound(SegmentBounds, char_pos, m.shared.segments.items, {}, lessThan);
    return m.shared.segments.items[elem -| 1].start;
}
