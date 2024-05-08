const std = @import("std");
const c = @import("c.zig");

pub const VideoFrame = struct {
    width: usize,
    height: usize,
    stride: usize,
    pts: f32,
    y: []const u8,
    u: []const u8,
    v: []const u8,
};

const VideoDecoderError = error{
    Unimplemented,
    InvalidData,
    OutOfMemory,
    InternalError,
};

pub const VideoDecoder = struct {
    const stream_idx: usize = 0;

    fmt_ctx: *c.AVFormatContext,
    decoder_ctx: *c.AVCodecContext,
    frame: *c.AVFrame,
    packet: *c.AVPacket,

    fn makeFormatCtx(path: [:0]const u8) VideoDecoderError!*c.AVFormatContext {
        var fmt_ctx_opt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt_ctx_opt, path, null, null) < 0) {
            std.log.err("Failed to open video", .{});
            return VideoDecoderError.InvalidData;
        }

        return fmt_ctx_opt.?;
    }

    fn makeDecoderCtx(fmt_ctx: *c.AVFormatContext) VideoDecoderError!*c.AVCodecContext {
        if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
            std.log.err("Failed to find stream info", .{});
            return VideoDecoderError.InternalError;
        }

        if (fmt_ctx.nb_streams < 1) {
            std.log.err("Input has no streams", .{});
            return VideoDecoderError.Unimplemented;
        }

        const stream = fmt_ctx.streams[stream_idx].*;
        if (stream.codecpar.*.codec_type != c.AVMEDIA_TYPE_VIDEO) {
            std.log.err("First stream is not video", .{});
            return VideoDecoderError.Unimplemented;
        }

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

        return decoder_ctx;
    }

    fn makeFrame() VideoDecoderError!*c.AVFrame {
        return c.av_frame_alloc() orelse {
            std.log.err("Failed to alloc frame", .{});
            return VideoDecoderError.OutOfMemory;
        };
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

    pub fn init(path: [:0]const u8) VideoDecoderError!VideoDecoder {
        const fmt_ctx = try makeFormatCtx(path);
        errdefer c.avformat_free_context(fmt_ctx);

        var decoder_ctx = try makeDecoderCtx(fmt_ctx);
        errdefer c.avcodec_free_context(@ptrCast(&decoder_ctx));

        var frame = try makeFrame();
        errdefer c.av_frame_free(@ptrCast(&frame));

        var pkt = try makePacket();
        errdefer c.av_packet_free(@ptrCast(&pkt));

        return .{
            .fmt_ctx = fmt_ctx,
            .decoder_ctx = decoder_ctx,
            .frame = frame,
            .packet = pkt,
        };
    }

    pub fn deinit(self: *VideoDecoder) void {
        c.av_packet_free(@ptrCast(&self.packet));
        c.av_frame_free(@ptrCast(&self.frame));
        c.avcodec_free_context(@ptrCast(&self.decoder_ctx));
        c.avformat_close_input(@ptrCast(&self.fmt_ctx));
        c.avformat_free_context(self.fmt_ctx);
    }

    pub fn next(self: *VideoDecoder) VideoDecoderError!VideoFrame {
        c.av_frame_unref(self.frame);
        while (true) {
            c.av_packet_unref(self.packet);
            if (c.av_read_frame(self.fmt_ctx, self.packet) < 0) {
                std.log.err("failed to read frame", .{});
                return error.InvalidData;
            }

            if (self.packet.stream_index != stream_idx) {
                continue;
            }

            if (c.avcodec_send_packet(self.decoder_ctx, self.packet) < 0) {
                std.log.err("failed to send packet to decoder", .{});
                return VideoDecoderError.InvalidData;
            }

            if (c.avcodec_receive_frame(self.decoder_ctx, self.frame) < 0) {
                std.log.err("failed to turn packet into frame", .{});
                return VideoDecoderError.InvalidData;
            }

            if (self.frame.format != c.AV_PIX_FMT_YUV420P) {
                // Major assumption made in OpenGL conversion about data format
                std.log.err("Unsupported frame format: {s}", .{c.av_get_pix_fmt_name(self.frame.format)});
                return VideoDecoderError.Unimplemented;
            }

            const width: usize = @intCast(self.frame.width);
            const height: usize = @intCast(self.frame.height);
            const stride: usize = @intCast(self.frame.linesize[0]);

            const colorspace = resolveColorspaceYuv(self.frame.colorspace, height);

            if (colorspace != c.AVCOL_SPC_BT470BG) {
                // Major assumption made in OpenGL conversion about data format
                std.log.err("Unsupported colorspace: {d}", .{self.frame.colorspace});
                return VideoDecoderError.Unimplemented;
            }

            if (self.frame.linesize[1] != @divTrunc(self.frame.linesize[0], 2) or self.frame.linesize[2] != @divTrunc(self.frame.linesize[0], 2)) {
                std.log.err("Assumption that UV channel stride is half Y stride is not true", .{});
                return VideoDecoderError.Unimplemented;
            }

            const y = self.frame.data[0][0 .. stride * height];
            const u = self.frame.data[1][0 .. y.len / 4];
            const v = self.frame.data[2][0 .. y.len / 4];

            var pts: f32 = @floatFromInt(self.frame.pts);
            const time_base = self.fmt_ctx.streams[stream_idx].*.time_base;
            pts *= @floatFromInt(time_base.num);
            pts /= @floatFromInt(time_base.den);

            return .{
                .stride = @intCast(stride),
                .width = width,
                .height = height,
                .y = y,
                .u = u,
                .v = v,
                .pts = pts,
            };
        }
    }
};
