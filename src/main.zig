const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");
});

fn errorCallback(err: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("glfw error {d}: {s}", .{ err, description });
}

fn glDebugCallback(source: c.GLenum, typ: c.GLenum, id: c.GLuint, severity: c.GLenum, length: c.GLsizei, message: [*c]const c.GLchar, user_param: ?*const anyopaque) callconv(.C) void {
    _ = source;
    _ = id;
    _ = severity;
    _ = length;
    _ = user_param;

    if (typ != c.GL_DEBUG_TYPE_ERROR) {
        return;
    }
    std.log.err("{s}", .{message});
}

const Image = struct {
    width: usize,
    height: usize,
    stride: usize,
    data: []const u8,
};

const VideoDecoderError = error{
    Unimplemented,
    InvalidData,
    OutOfMemory,
    InternalError,
};

const VideoDecoder = struct {
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

        const stream = fmt_ctx.streams[0].*;
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

    pub fn next(self: *VideoDecoder) VideoDecoderError!Image {
        if (c.av_read_frame(self.fmt_ctx, self.packet) < 0) {
            std.log.err("failed to read frame", .{});
            return error.InvalidData;
        }

        if (c.avcodec_send_packet(self.decoder_ctx, self.packet) < 0) {
            std.log.err("failed to send packet to decoder", .{});
            return VideoDecoderError.InvalidData;
        }

        if (c.avcodec_receive_frame(self.decoder_ctx, self.frame) < 0) {
            std.log.err("failed to turn packet into frame", .{});
            return VideoDecoderError.InvalidData;
        }

        if (self.frame.format != c.AV_PIX_FMT_RGBA) {
            // Major assumption made in OpenGL conversion about data format
            std.log.err("Unsupported frame format: {s}", .{c.av_get_pix_fmt_name(self.frame.format)});
            return VideoDecoderError.Unimplemented;
        }

        const width: usize = @intCast(self.frame.width);
        const height: usize = @intCast(self.frame.height);
        const stride: usize = @intCast(self.frame.linesize[0]);
        const data = self.frame.data[0][0 .. stride * height];

        return .{
            .stride = @intCast(stride),
            .width = width,
            .height = height,
            .data = data,
        };
    }
};

fn imgToTexture(image: Image) c.GLuint {
    var texture: c.GLuint = undefined;
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    // set the texture wrapping/filtering options (on the currently bound texture object)
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    // FIXME: Hugely incorrect assumption about RGBA
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(image.stride / 4), @intCast(image.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.data.ptr);
    return texture;
}

const ArgParseError = std.process.ArgIterator.InitError;

const Args = struct {
    it: std.process.ArgIterator,
    input: [:0]const u8,
    lint: bool,

    const Switch = enum {
        @"--input",
        @"--lint",
        @"--help",

        fn parse(s: []const u8) ?Switch {
            inline for (std.meta.fields(Switch)) |f| {
                if (std.mem.eql(u8, f.name, s)) {
                    return @enumFromInt(f.value);
                }
            }

            return null;
        }
    };

    fn print(comptime fmt: []const u8, params: anytype) void {
        std.io.getStdErr().writer().print(fmt, params) catch {};
    }

    pub fn init(alloc: std.mem.Allocator) ArgParseError!Args {
        var args = try std.process.argsWithAllocator(alloc);

        var lint = false;
        var input: ?[:0]const u8 = null;
        const process_name = args.next() orelse "video-editor";
        while (args.next()) |arg| {
            const s = Switch.parse(arg) orelse {
                print("unrecognized argument: {s}\n", .{arg});
                help(process_name);
            };

            switch (s) {
                .@"--input" => {
                    input = args.next() orelse {
                        print("--input provided with no file\n", .{});
                        help(process_name);
                    };
                },
                .@"--lint" => {
                    lint = true;
                },
                .@"--help" => {
                    help(process_name);
                },
            }
        }

        return .{
            .it = args,
            .input = input orelse {
                unreachable;
            },
            .lint = lint,
        };
    }

    fn help(process_name: []const u8) noreturn {
        print("Usage: {s} [ARGS]\n\nARGS:\n", .{process_name});

        inline for (std.meta.fields(Switch)) |s| {
            print("{s}: ", .{s.name});
            const value: Switch = @enumFromInt(s.value);
            switch (value) {
                .@"--input" => {
                    print("File to work with", .{});
                },
                .@"--lint" => {
                    print("Optional, if passed will set params to make linting easier", .{});
                },
                .@"--help" => {
                    print("Show this help", .{});
                },
            }
            print("\n", .{});
        }

        std.process.exit(1);
    }

    pub fn deinit(self: *Args) void {
        self.it.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.init(alloc);
    defer args.deinit();

    if (c.glfwInit() == c.GLFW_FALSE) {
        std.log.err("failed to init glfw", .{});
        return error.Initialization;
    }

    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(errorCallback);

    const window = c.glfwCreateWindow(640, 480, "My Title", null, null) orelse {
        std.log.err("failed to create glfw window", .{});
        return error.Initialization;
    };

    defer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);
    if (c.gladLoadGL() == 0) {
        std.log.err("failed to init glad", .{});
        return error.Initialization;
    }

    c.glfwSwapInterval(1);

    c.glEnable(c.GL_DEBUG_OUTPUT);
    c.glDebugMessageCallback(glDebugCallback, null);

    const vert_shader_source: [*c]const u8 =
        \\#version 330 core
        \\
        \\out vec2 vert_coord_2d;
        \\void main()
        \\{
        \\  const vec4 vertices[4] = vec4[](
        \\    vec4(-0.5, -0.5, 0.0, 1.0),
        \\    vec4(0.5, -0.5, 0.0, 1.0),
        \\    vec4(-0.5, 0.5, 0.0, 1.0),
        \\    vec4(0.5, 0.5, 0.0, 1.0)
        \\  );
        \\  vert_coord_2d = vec2(vertices[gl_VertexID].x, vertices[gl_VertexID].y);
        \\  gl_Position = vertices[gl_VertexID];
        \\}
    ;

    const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
    defer c.glDeleteShader(vertex_shader);
    c.glShaderSource(vertex_shader, 1, &vert_shader_source, null);
    c.glCompileShader(vertex_shader);

    const frag_shader_source: [*c]const u8 =
        \\#version 330
        \\in vec2 vert_coord_2d;
        \\out vec4 fragment;
        \\uniform sampler2D tex;
        \\void main()
        \\{
        \\    vec2 frag_coord = vert_coord_2d + 0.5;
        \\    frag_coord.y *= -1;
        \\    fragment = texture(tex, frag_coord);
        \\}
    ;

    const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    defer c.glDeleteShader(fragment_shader);
    c.glShaderSource(fragment_shader, 1, &frag_shader_source, null);
    c.glCompileShader(fragment_shader);

    const program = c.glCreateProgram();
    defer c.glDeleteProgram(program);
    c.glAttachShader(program, vertex_shader);
    c.glAttachShader(program, fragment_shader);
    c.glLinkProgram(program);

    c.glClearColor(0.0, 0.0, 1.0, 1.0);

    var decoder = try VideoDecoder.init(args.input);
    defer decoder.deinit();

    const img = try decoder.next();
    const texture = imgToTexture(img);
    defer c.glDeleteTextures(1, &texture);

    while (c.glfwWindowShouldClose(window) == 0) {
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.glfwGetFramebufferSize(window, &width, &height);
        c.glViewport(0, 0, width, height);

        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glUseProgram(program);

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);

        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

        c.glfwSwapBuffers(window);

        if (args.lint) {
            c.glfwSetWindowShouldClose(window, 1);
        }
    }
}
