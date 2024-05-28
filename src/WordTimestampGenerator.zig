const c = @import("c.zig");
const decoder = @import("decoder.zig");
const std = @import("std");
const audio = @import("audio.zig");
const save = @import("save.zig");
const WavWriter = @import("WavWriter.zig");
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
    split_threshold_s: f32 = 1.0,
    split_indices: std.ArrayList(u64),
    num_samples_processed: usize,
    // No mutex lock necessary
    shutdown: std.atomic.Value(bool),

    fn deinit(self: *Shared) void {
        self.segments.deinit();
        self.text.deinit();
        self.split_indices.deinit();
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

    fn init(dec: *decoder.VideoDecoder) !WhisperInputResampler {
        const stream = try findFirstAudioStream(dec) orelse {
            return error.NoAudio;
        };
        std.debug.assert(stream.format == audio.Format.f32);

        const frame = try dec.next(stream.stream_id) orelse {
            return error.NoAudio;
        };

        return .{
            .stream = stream,
            .dec = dec,
            .frame = frame.audio,
            .frame_start = 0,
            .output_samples = 0,
        };
    }

    fn deinit(self: *WhisperInputResampler) void {
        self.frame.deinit();
    }

    // Returns the next sample at the requested rate
    fn next(self: *WhisperInputResampler) !?[]const u8 {
        while (true) {
            const input_idx = self.output_samples * self.stream.sample_rate / whisper_sample_rate;
            const frame_idx = input_idx - self.frame_start;

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

fn pushWhisperSegments(segment_it: *WhisperRunner.SegmentIt, shared: *Shared) !void {
    shared.mutex.lock();
    defer shared.mutex.unlock();

    if (shared.segments.items.len == 0) {
        const whisper_segment = segment_it.next() orelse {
            return;
        };
        const segment = SegmentBounds{
            .start = whisper_segment.start_s,
            .end = whisper_segment.end_s,
            .char_start = shared.text.items.len,
            .char_end = shared.text.items.len + whisper_segment.text.len,
        };

        try shared.segments.append(segment);
        try shared.segments.append(segment);
        try shared.text.appendSlice(whisper_segment.text);
    }

    var last_segment = shared.segments.items[shared.segments.items.len - 1];

    while (segment_it.next()) |whisper_segment| {
        const segment = SegmentBounds{
            .start = whisper_segment.start_s,
            .end = whisper_segment.end_s,
            .char_start = shared.text.items.len,
            .char_end = shared.text.items.len + whisper_segment.text.len,
        };

        try shared.segments.append(segment);
        try shared.text.appendSlice(whisper_segment.text);

        if (last_segment.end + shared.split_threshold_s <= segment.start) {
            try shared.split_indices.append(segment.char_start);
        }

        last_segment = segment;
    }
}

// ffmpeg -> []const u8, format tag

const DebugOutput = struct {
    folder: ?[]const u8,

    fn init(debug_output_path: ?[]const u8) !DebugOutput {
        if (debug_output_path) |p| {
            try std.fs.cwd().makePath(p);
        }
        return .{
            .folder = debug_output_path,
        };
    }

    fn generateFileName(self: *DebugOutput, alloc: Allocator, start_sample: usize, end_sample: usize, ext: []const u8) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{d}_{d}.{s}", .{self.folder.?, start_sample, end_sample, ext});
    }

    fn writeWhisperIo(self: *DebugOutput, alloc: Allocator, audio_buf: []const u8, text: []const u8, start_sample: usize, end_sample: usize) !void {
        if (self.folder == null) {
            return;
        }

        const audio_file_name = try self.generateFileName(alloc, start_sample, end_sample, "wav");
        defer alloc.free(audio_file_name);

        const text_file_name = try self.generateFileName(alloc, start_sample, end_sample, "txt");
        defer alloc.free(text_file_name);

        var wav_writer = try WavWriter.init(alloc, whisper_sample_rate, 1, audio.Format.f32, audio_file_name);
        defer wav_writer.deinit();

        try wav_writer.writeAudio(audio_buf);

        var text_output = try std.fs.cwd().createFile(text_file_name, .{
            .truncate = true,
        });
        defer text_output.close();

        try text_output.writeAll(text);
    }
};

fn initThread(alloc: Allocator, path: [:0]const u8, shared: *Shared, debug_output_path: ?[]const u8) !void {
    var debug_output = try DebugOutput.init(debug_output_path);

    var dec = try decoder.VideoDecoder.init(alloc, path);
    defer dec.deinit();

    var sampler = try WhisperInputResampler.init(&dec);
    defer sampler.deinit();

    for (shared.num_samples_processed) |_| {
        _ = try sampler.next();
    }

    c.whisper_log_set(logCallback, null);

    const sample_size = sampler.stream.format.sampleSize();
    const buf_size_s = 8;
    var audio_buf = try alloc.alloc(u8, whisper_sample_rate * buf_size_s * sample_size);
    defer alloc.free(audio_buf);

    var buf_pos: usize = 0;

    var whisper = try WhisperRunner.init(&shared.shutdown);
    defer whisper.deinit();
    whisper.start_time_ms = @divTrunc(@as(i64, @intCast(shared.num_samples_processed)) * 1000, whisper_sample_rate);

    while (!shared.shutdown.load(std.builtin.AtomicOrder.unordered)) {
        const data = try sampler.next() orelse {
            break;
        };
        @memcpy(audio_buf[buf_pos .. buf_pos + data.len], data);
        buf_pos += data.len;

        if (buf_pos == audio_buf.len) {
            var segment_it = whisper.next(audio_buf) catch |e| {
                if (shared.shutdown.load(std.builtin.AtomicOrder.unordered)) {
                    return;
                }
                return e;
            };

            shared.mutex.lock();
            const text_start = shared.text.items.len;
            shared.mutex.unlock();

            try pushWhisperSegments(&segment_it, shared);
            shared.num_samples_processed += buf_size_s * whisper_sample_rate;

            const end_sample = sampler.output_samples;
            const start_sample = end_sample - whisper_sample_rate * buf_size_s;

            shared.mutex.lock();
            defer shared.mutex.unlock();
            try debug_output.writeWhisperIo(alloc, audio_buf, shared.text.items[text_start..shared.text.items.len], start_sample, end_sample);

            buf_pos = 0;
        }
    }

    var segment_it = try whisper.next(audio_buf[0..buf_pos]);
    try pushWhisperSegments(&segment_it, shared);
}

pub fn init(alloc: Allocator, path: [:0]const u8, init_data: ?save.Data.Field, debug_output: ?[]const u8) !Whisper {
    var segments = std.ArrayList(SegmentBounds).init(alloc);
    errdefer segments.deinit();

    var text = std.ArrayList(u8).init(alloc);
    errdefer text.deinit();

    const shared = try alloc.create(Shared);
    errdefer alloc.destroy(shared);
    shared.* = try sharedFromInitData(alloc, init_data);

    const init_thread = try Thread.spawn(.{}, initThread, .{ alloc, path, shared, debug_output });

    var ret = Whisper{
        .alloc = alloc,
        .init_thread = init_thread,
        .shared = shared,
    };

    shared.mutex.lock();
    const split_threshold = shared.split_threshold_s;
    shared.mutex.unlock();

    try ret.setSplitThreshold(split_threshold);
    return ret;
}

pub fn deinit(self: *Whisper) void {
    self.shared.shutdown.store(true, std.builtin.AtomicOrder.unordered);
    self.init_thread.join();
    self.shared.deinit();
    self.alloc.destroy(self.shared);
}

pub const SaveData = struct {
    text: []const u8,
    segment_timestamps: []const SegmentBounds,
    split_threshold_s: f32,
    num_samples_processed: usize,
};

pub fn serialize(self: *Whisper, writer: save.Writer.FieldWriter) !void {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();

    const data = SaveData{
        .text = self.shared.text.items,
        .segment_timestamps = self.shared.segments.items,
        .split_threshold_s = self.shared.split_threshold_s,
        .num_samples_processed = self.shared.num_samples_processed,
    };
    try writer.write(data);
}

// How much time passes between words before we newline
pub fn setSplitThreshold(self: *Whisper, threshold_s: f32) !void {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();

    var split_indices = std.ArrayList(u64).init(self.alloc);
    errdefer split_indices.deinit();

    const segments = self.shared.segments.items;
    for (0..segments.len -| 1) |i| {
        const a = &segments[i];
        const b = &segments[i + 1];

        if (a.end + threshold_s <= b.start) {
            try split_indices.append(b.char_start);
        }
    }

    self.shared.split_indices.deinit();
    self.shared.split_indices = split_indices;

    for (self.shared.segments.items) |segment| {
        std.debug.print("[{d}-->{d}] {s}\n", .{ segment.start, segment.end, self.shared.text.items[segment.char_start..segment.char_end] });
    }

    var last_split_idx: usize = 0;
    for (self.shared.split_indices.items) |split_idx| {
        std.debug.print("{s}\n", .{self.shared.text.items[last_split_idx..split_idx]});
        last_split_idx = split_idx;
    }

    std.debug.print("split indices: {any}\n", .{split_indices});
    self.shared.split_threshold_s = threshold_s;
}

fn sharedFromInitData(alloc: Allocator, init_data: ?save.Data.Field) !Shared {
    var segments = std.ArrayList(SegmentBounds).init(alloc);
    errdefer segments.deinit();

    var text = std.ArrayList(u8).init(alloc);
    errdefer text.deinit();

    var split_indices = std.ArrayList(u64).init(alloc);
    errdefer split_indices.deinit();

    if (init_data == null) {
        return Shared{
            .mutex = .{},
            .segments = segments,
            .text = text,
            .shutdown = std.atomic.Value(bool).init(false),
            .split_indices = split_indices,
            .num_samples_processed = 0,
        };
    }

    const parsed = try init_data.?.as(SaveData);
    defer parsed.deinit();

    try segments.appendSlice(parsed.value.segment_timestamps);
    try text.appendSlice(parsed.value.text);

    return Shared{
        .mutex = .{},
        .segments = segments,
        .text = text,
        .shutdown = std.atomic.Value(bool).init(false),
        .split_indices = split_indices,
        .num_samples_processed = parsed.value.num_samples_processed,
        .split_threshold_s = parsed.value.split_threshold_s,
    };
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
