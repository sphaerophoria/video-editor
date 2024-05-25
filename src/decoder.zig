const std = @import("std");
const c = @import("c.zig");
const audio = @import("audio.zig");
const Allocator = std.mem.Allocator;

pub const FramePool = struct {
    // Frames may be released from other threads
    mutex: std.Thread.Mutex,
    // All allocated AVFrames. Some may be in use
    pool: std.ArrayList(*c.AVFrame),
    // Frames ready to be reused
    free_ids: std.ArrayList(usize),

    pub fn init(alloc: Allocator) FramePool {
        return .{
            .mutex = std.Thread.Mutex{},
            .pool = std.ArrayList(*c.AVFrame).init(alloc),
            .free_ids = std.ArrayList(usize).init(alloc),
        };
    }

    pub fn deinit(self: *FramePool) void {
        // No mutex lock, if someone is still using us we shouldn't be trying
        // to destruct
        for (self.pool.items) |*item| {
            c.av_frame_free(@ptrCast(item));
        }

        self.pool.deinit();
        self.free_ids.deinit();
    }

    fn allocateFrame(self: *FramePool) VideoDecoderError!void {
        var new_frame = try makeFrame();
        errdefer c.av_frame_free(@ptrCast(&new_frame));

        try self.pool.append(new_frame);
        errdefer _ = self.pool.pop();

        try self.free_ids.append(self.pool.items.len - 1);
    }

    pub fn acquire(self: *FramePool) VideoDecoderError!usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_ids.items.len == 0) {
            try self.allocateFrame();
        }
        return self.free_ids.pop();
    }

    pub fn release(self: *FramePool, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        c.av_frame_unref(self.pool.items[id]);
        self.free_ids.append(id) catch {
            _ = self.pool.swapRemove(id);
        };
    }
};

pub const VideoFrame = struct {
    stream_id: usize,
    width: usize,
    height: usize,
    stride: usize,
    pts: f32,
    y: []const u8,
    u: []const u8,
    v: []const u8,
    frame_pool: *FramePool,
    frame_id: usize,

    pub fn deinit(self: *VideoFrame) void {
        self.frame_pool.release(self.frame_id);
    }
};

pub const AudioStreamInfo = struct {
    stream_id: usize,
    format: audio.Format,
    sample_rate: usize,
    num_channels: usize,
};

pub const AudioFrame = struct {
    info: AudioStreamInfo,
    num_samples: usize,
    channel_data: std.ArrayList([]const u8),
    pts: f32,
    frame_pool: *FramePool,
    frame_id: usize,

    pub fn deinit(self: *AudioFrame) void {
        self.frame_pool.release(self.frame_id);
        self.channel_data.deinit();
    }
};

pub const Frame = union(enum) {
    audio: AudioFrame,
    video: VideoFrame,

    pub fn pts(self: *const Frame) f32 {
        switch (self.*) {
            .audio => |af| return af.pts,
            .video => |vf| return vf.pts,
        }
    }

    pub fn deinit(self: *Frame) void {
        switch (self.*) {
            .audio => |*af| af.deinit(),
            .video => |*vf| vf.deinit(),
        }
    }
};

pub const StreamIt = struct {
    fmt_ctx: *c.AVFormatContext,
    i: usize,

    const Output = union(enum) {
        video: struct {
            stream_id: usize,
        },
        audio: AudioStreamInfo,
        unknown: void,
    };

    pub fn next(self: *StreamIt) !?Output {
        if (self.i >= self.fmt_ctx.nb_streams) {
            return null;
        }

        defer self.i += 1;
        const stream: *c.AVStream = self.fmt_ctx.streams[self.i];
        // NOTE: There is a stream ID in the stream info, but we
        // only care about it as far as we want to index into our
        // streams array. Using the ffmpeg id is just more confusing
        // and complex
        const id = self.i;
        const codec_params = stream.codecpar.*;
        const codec_type = codec_params.codec_type;

        switch (codec_type) {
            c.AVMEDIA_TYPE_VIDEO => {
                return .{
                    .video = .{
                        .stream_id = id,
                    },
                };
            },
            c.AVMEDIA_TYPE_AUDIO => {
                const format = try ffmpegFormatToAudioFormat(codec_params.format);
                const sample_rate = try cIntToUsize(codec_params.sample_rate, "sample rate");
                const num_channels = try cIntToUsize(codec_params.ch_layout.nb_channels, "number of channels");
                return .{
                    .audio = .{
                        .stream_id = id,
                        .format = format,
                        .sample_rate = sample_rate,
                        .num_channels = num_channels,
                    },
                };
            },
            else => {
                std.log.err("Unhandled codec type: {d}", .{codec_type});
                return .{
                    .unknown = {},
                };
            },
        }
    }
};

const VideoDecoderError = error{
    Again,
    Unimplemented,
    InvalidData,
    OutOfMemory,
    InternalError,
    InvalidArg,
    Eof,
};

pub const VideoDecoder = struct {
    alloc: Allocator,
    fmt_ctx: *c.AVFormatContext,
    decoder_ctxs: std.ArrayList(*c.AVCodecContext),
    frame_pool: FramePool,
    packet: *c.AVPacket,
    duration: f32,

    fn freeDecoderContexts(ctxs: *std.ArrayList(*c.AVCodecContext)) void {
        for (ctxs.items) |*ctx| {
            c.avcodec_free_context(@ptrCast(ctx));
        }

        ctxs.deinit();
    }

    fn makeFormatCtx(path: [:0]const u8) VideoDecoderError!*c.AVFormatContext {
        var fmt_ctx_opt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_ctx_opt, path, null, null) < 0) {
            std.log.err("Failed to open video", .{});
            return VideoDecoderError.InvalidData;
        }

        return fmt_ctx_opt.?;
    }

    fn makeDecoderCtxs(alloc: Allocator, fmt_ctx: *c.AVFormatContext) VideoDecoderError!std.ArrayList(*c.AVCodecContext) {
        if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
            std.log.err("Failed to find stream info", .{});
            return VideoDecoderError.InternalError;
        }

        var ret = std.ArrayList(*c.AVCodecContext).init(alloc);
        errdefer freeDecoderContexts(&ret);

        for (0..fmt_ctx.nb_streams) |i| {
            const stream = fmt_ctx.streams[i].*;

            const codec_id = stream.codecpar.*.codec_id;
            const codec = c.avcodec_find_decoder(codec_id);

            var decoder_ctx = c.avcodec_alloc_context3(codec) orelse {
                std.log.err("Failed to create decoder", .{});
                return VideoDecoderError.InternalError;
            };
            errdefer c.avcodec_free_context(&decoder_ctx);

            if (c.avcodec_parameters_to_context(decoder_ctx, stream.codecpar) < 0) {
                std.log.err("Failed to copy codec parameters", .{});
                return VideoDecoderError.InternalError;
            }

            if (c.avcodec_open2(decoder_ctx, codec, null) < 0) {
                std.log.err("Failed to open codec", .{});
                return VideoDecoderError.InternalError;
            }

            try ret.append(decoder_ctx);
        }

        return ret;
    }

    fn makePacket() VideoDecoderError!*c.AVPacket {
        return c.av_packet_alloc() orelse {
            std.log.err("Failed to alloc packet", .{});
            return VideoDecoderError.OutOfMemory;
        };
    }

    // Color conversion depends on the color space
    // Color space may be unspecified
    // If unspecified, we use heuristics to determine what the best fit
    // would be
    fn resolveColorspaceYuv(colorspace: c.AVColorSpace, height: usize) c.AVColorSpace {
        // Looking at ffplay -> SDL code, it seems that in this case ffplay
        // decides to use SDL's automatic YUV mode, which essentially follows
        // this logic
        const yuv_sd_threshold = 576;
        if (colorspace != c.AVCOL_SPC_UNSPECIFIED) {
            return colorspace;
        }

        if (height <= yuv_sd_threshold) {
            return c.AVCOL_SPC_BT470BG;
        } else {
            return c.AVCOL_SPC_BT709;
        }
    }

    pub fn init(alloc: Allocator, path: [:0]const u8) VideoDecoderError!VideoDecoder {
        const fmt_ctx = try makeFormatCtx(path);
        errdefer c.avformat_free_context(fmt_ctx);

        var decoder_ctxs = try makeDecoderCtxs(alloc, fmt_ctx);
        errdefer freeDecoderContexts(&decoder_ctxs);

        var frame_pool = FramePool.init(alloc);
        errdefer frame_pool.deinit();

        var pkt = try makePacket();
        errdefer c.av_packet_free(@ptrCast(&pkt));

        const duration = try detectDuration(fmt_ctx, pkt);

        return .{
            .alloc = alloc,
            .fmt_ctx = fmt_ctx,
            .decoder_ctxs = decoder_ctxs,
            .frame_pool = frame_pool,
            .packet = pkt,
            .duration = duration,
        };
    }

    pub fn streams(self: *VideoDecoder) StreamIt {
        return .{
            .fmt_ctx = self.fmt_ctx,
            .i = 0,
        };
    }

    pub fn deinit(self: *VideoDecoder) void {
        c.av_packet_free(@ptrCast(&self.packet));
        self.frame_pool.deinit();
        freeDecoderContexts(&self.decoder_ctxs);
        c.avformat_close_input(@ptrCast(&self.fmt_ctx));
        c.avformat_free_context(self.fmt_ctx);
    }

    pub fn seek(self: *VideoDecoder, pts: f32, stream_id: usize) VideoDecoderError!void {
        const time_base = self.fmt_ctx.streams[stream_id].*.time_base;
        const pts_tb = secondsToTimeBase(pts, time_base);
        if (c.avformat_flush(self.fmt_ctx) < 0) {
            std.log.err("Failed to flush ffmpeg context", .{});
            return VideoDecoderError.InternalError;
        }

        if (c.av_seek_frame(self.fmt_ctx, @intCast(stream_id), pts_tb, c.AVSEEK_FLAG_BACKWARD) < 0) {
            std.log.err("Failed to seek to {d}", .{pts});
            return VideoDecoderError.InvalidArg;
        }

        for (self.decoder_ctxs.items) |decoder_ctx| {
            c.avcodec_flush_buffers(decoder_ctx);
        }
    }

    pub fn handleVideoFrame(self: *VideoDecoder, frame_id: usize) VideoDecoderError!Frame {
        const frame = self.frame_pool.pool.items[frame_id];
        if (frame.format != c.AV_PIX_FMT_YUV420P) {
            // Major assumption made in OpenGL conversion about data format
            std.log.err("Unsupported frame format: {s}", .{c.av_get_pix_fmt_name(frame.format)});
            return VideoDecoderError.Unimplemented;
        }

        const width = try cIntToUsize(frame.width, "frame width");
        const height = try cIntToUsize(frame.height, "frame height");
        const stride = try cIntToUsize(frame.linesize[0], "frame stride");

        const colorspace = resolveColorspaceYuv(frame.colorspace, height);

        if (colorspace != c.AVCOL_SPC_BT470BG) {
            const already = struct {
                var warned: bool = false;
            };

            if (!already.warned) {
                // Major assumption made in OpenGL conversion about data format
                std.log.warn("Unsupported colorspace: {d}", .{frame.colorspace});
                already.warned = true;
            }
        }

        if (frame.linesize[1] != @divTrunc(frame.linesize[0], 2) or frame.linesize[2] != @divTrunc(frame.linesize[0], 2)) {
            std.log.err("Assumption that UV channel stride is half Y stride is not true", .{});
            return VideoDecoderError.Unimplemented;
        }

        const y = frame.data[0][0 .. stride * height];
        const u = frame.data[1][0 .. y.len / 4];
        const v = frame.data[2][0 .. y.len / 4];

        const time_base = self.fmt_ctx.streams[@intCast(self.packet.stream_index)].*.time_base;
        const pts = timeBaseToSeconds(frame.pts, time_base);

        return .{ .video = .{
            .stream_id = @intCast(self.packet.stream_index),
            .stride = stride,
            .width = width,
            .height = height,
            .y = y,
            .u = u,
            .v = v,
            .pts = pts,
            .frame_pool = &self.frame_pool,
            .frame_id = frame_id,
        } };
    }

    pub fn handleAudioFrame(self: *VideoDecoder, frame_id: usize) VideoDecoderError!?Frame {
        const frame = self.frame_pool.pool.items[frame_id];

        const format = try ffmpegFormatToAudioFormat(frame.format);

        var channel_data = std.ArrayList([]const u8).init(self.alloc);
        errdefer channel_data.deinit();

        const nb_channels = try cIntToUsize(frame.ch_layout.nb_channels, "frame channels");
        const nb_samples = try cIntToUsize(frame.nb_samples, "audio samples");
        const data_len = nb_samples * format.sampleSize();

        for (0..nb_channels) |c_num| {
            const data_ptr = frame.extended_data[c_num];
            try channel_data.append(data_ptr[0..data_len]);
        }

        const time_base = self.fmt_ctx.streams[@intCast(self.packet.stream_index)].*.time_base;
        const pts = timeBaseToSeconds(frame.pts, time_base);

        std.debug.assert(self.packet.stream_index >= 0); // Should have been checked in parent function

        return .{
            .audio = .{
                .info = .{
                    .stream_id = @intCast(self.packet.stream_index),
                    .format = format,
                    .sample_rate = @intCast(frame.sample_rate),
                    .num_channels = channel_data.items.len,
                },
                .pts = pts,
                .num_samples = nb_samples,
                .channel_data = channel_data,
                .frame_pool = &self.frame_pool,
                .frame_id = frame_id,
            },
        };
    }

    const NextFrame = struct {
        frame_id: usize,
        stream_id: usize,
    };

    fn readNextFrame(self: *VideoDecoder, stream_id: ?usize) VideoDecoderError!NextFrame {
        while (true) {
            c.av_packet_unref(self.packet);
            const av_read_frame_ret = c.av_read_frame(self.fmt_ctx, self.packet);
            if (av_read_frame_ret == c.AVERROR_EOF) {
                return VideoDecoderError.Eof;
            }
            if (av_read_frame_ret < 0) {
                std.log.err("failed to read frame", .{});
                return error.InvalidData;
            }

            if (stream_id != null and self.packet.stream_index != stream_id.?) {
                continue;
            }

            if (self.packet.stream_index >= self.decoder_ctxs.items.len or self.packet.stream_index < 0) {
                std.log.err("got frame for stream that does not exist", .{});
                return VideoDecoderError.InvalidData;
            }

            const stream_index: usize = @intCast(self.packet.stream_index);
            const decoder_ctx = self.decoder_ctxs.items[stream_index];

            if (c.avcodec_send_packet(decoder_ctx, self.packet) < 0) {
                std.log.err("failed to send packet to decoder", .{});
                return VideoDecoderError.InvalidData;
            }

            const frame_id = try self.frame_pool.acquire();
            errdefer self.frame_pool.release(frame_id);
            const frame = self.frame_pool.pool.items[frame_id];

            const ret = c.avcodec_receive_frame(decoder_ctx, frame);
            if (ret == c.AVERROR(c.EAGAIN)) {
                // This simplifies the error handling path, even though we could
                // just directly try again
                return VideoDecoderError.Again;
            } else if (ret < 0) {
                std.log.err("failed to turn packet into frame: {d}", .{ret});
                return VideoDecoderError.InvalidData;
            }

            return .{
                .frame_id = frame_id,
                .stream_id = stream_index,
            };
        }
    }

    pub fn next(self: *VideoDecoder, stream_id: ?usize) VideoDecoderError!?Frame {
        while (true) {
            const next_frame = self.readNextFrame(stream_id) catch |e| {
                if (e == VideoDecoderError.Again) {
                    continue;
                } else if (e == VideoDecoderError.Eof) {
                    return null;
                }

                return e;
            };

            const decoder_ctx = self.decoder_ctxs.items[next_frame.stream_id];

            switch (decoder_ctx.codec.*.type) {
                c.AVMEDIA_TYPE_VIDEO => {
                    return try self.handleVideoFrame(next_frame.frame_id);
                },
                c.AVMEDIA_TYPE_AUDIO => {
                    return try self.handleAudioFrame(next_frame.frame_id);
                },
                else => {
                    std.log.warn("Unknown codec type: {d}", .{decoder_ctx.codec.*.type});
                    self.frame_pool.release(next_frame.frame_id);
                    continue;
                },
            }
        }
    }
};

fn makeFrame() VideoDecoderError!*c.AVFrame {
    return c.av_frame_alloc() orelse {
        std.log.err("Failed to alloc frame", .{});
        return VideoDecoderError.OutOfMemory;
    };
}

fn cIntToUsize(in: c_int, purpose: []const u8) !usize {
    if (in < 0) {
        std.log.err("{s} was negative", .{purpose});
        return VideoDecoderError.InvalidData;
    }
    return @intCast(in);
}

fn ffmpegFormatToAudioFormat(format: c_int) VideoDecoderError!audio.Format {
    switch (format) {
        c.AV_SAMPLE_FMT_FLTP => {
            return audio.Format.f32;
        },
        else => {
            std.log.err("Unhandled audio sample format: {d}", .{format});
            return VideoDecoderError.Unimplemented;
        },
    }
}

fn timeBaseToSeconds(val_i: i64, time_base: c.AVRational) f32 {
    var val_f: f32 = @floatFromInt(val_i);
    val_f *= @floatFromInt(time_base.num);
    val_f /= @floatFromInt(time_base.den);
    return val_f;
}

fn secondsToTimeBase(val_s: f32, time_base: c.AVRational) i64 {
    var val_tb = val_s;
    val_tb *= @floatFromInt(time_base.den);
    val_tb /= @floatFromInt(time_base.num);
    return @intFromFloat(val_tb);
}

fn detectDuration(fmt_ctx: *c.AVFormatContext, packet: *c.AVPacket) !f32 {
    defer _ = c.av_seek_frame(fmt_ctx, 0, 0, 0);

    var max_pts: f32 = 0.0;
    if (c.av_seek_frame(fmt_ctx, 0, std.math.maxInt(i64), c.AVSEEK_FLAG_BACKWARD) < 0) {
        std.log.err("Failed to seek to end of file", .{});
        return VideoDecoderError.InternalError;
    }

    while (true) {
        c.av_packet_unref(packet);
        const av_read_frame_ret = c.av_read_frame(fmt_ctx, packet);
        defer c.av_packet_unref(packet);
        if (av_read_frame_ret == c.AVERROR_EOF) {
            break;
        }
        const time_base = fmt_ctx.streams[@intCast(packet.stream_index)].*.time_base;
        const pts = timeBaseToSeconds(packet.pts, time_base);
        max_pts = @max(max_pts, pts);
    }

    return max_pts;
}
