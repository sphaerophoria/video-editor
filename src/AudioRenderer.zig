const std = @import("std");
const decoder = @import("decoder.zig");
const Allocator = std.mem.Allocator;
const audio = @import("audio.zig");
const c = @import("c.zig");
const gl_helpers = @import("gl_helpers.zig");

pub export fn audiorenderer_render(self: *AudioRenderer, guigl: ?*anyopaque, zoom: f32, center_norm: f32) void {
    self.render(guigl, zoom, center_norm);
}

pub export fn audiorenderer_init_gl(self: *AudioRenderer, guigl: ?*anyopaque) void {
    self.initGl(guigl);
}

pub export fn audiorenderer_deinit_gl(self: *AudioRenderer, guigl: ?*anyopaque) void {
    self.deinitGl(guigl);
}

const AudioRenderer = @This();

const Sample = struct {
    min: f32,
    max: f32,
};

const InitThread = struct {
    // Copy of the file path that we can guarantee will be valid for the lifetime
    // of the init thread
    alloc: Allocator,
    path: [:0]const u8,
    shared: *InitData,

    fn init(alloc: Allocator, path: [:0]const u8, shared: *InitData) !*InitThread {
        const ret = try alloc.create(InitThread);
        errdefer alloc.destroy(ret);

        const path_copy = try alloc.allocSentinel(u8, path.len, 0);
        errdefer alloc.free(path_copy);
        @memcpy(path_copy, path);

        ret.* = .{
            .alloc = alloc,
            .path = path_copy,
            .shared = shared,
        };

        return ret;
    }

    fn deinit(self: *InitThread) void {
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }

    fn run_and_consume(self: *InitThread) !void {
        defer self.deinit();

        const target_memory_usage_bytes = 3 * 1024 * 1024;
        var dec = try decoder.VideoDecoder.init(self.alloc, self.path);
        defer dec.deinit();

        const stream_info = try findFirstAudioStream(&dec) orelse {
            std.log.err("No audio stream found", .{});
            return error.NoAudioStream;
        };

        const window_size = @max(10, calculateWindowSize(stream_info, dec.duration, target_memory_usage_bytes));

        // NOTE: This may be larger than the number of samples we actually
        // read. Without much root causing, the timeline lines up better if we
        // use the calculated value instead of the actual value. My intuition
        // here is that the audio frames can stop before the stream does, but I
        // have not verified
        const num_samples: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(stream_info.sample_rate)) * dec.duration / @as(f32, @floatFromInt(window_size))));

        {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            self.shared.num_samples = num_samples;
        }

        var sample = Sample{
            .max = -std.math.inf(f32),
            .min = std.math.inf(f32),
        };

        var num_samples_collected: usize = 0;

        while (!self.shared.shutdown.load(std.builtin.AtomicOrder.unordered)) {
            var frame = try dec.next(stream_info.stream_id) orelse {
                break;
            };
            defer frame.deinit();

            switch (frame) {
                .audio => |af| {
                    if (af.info.stream_id != stream_info.stream_id) {
                        continue;
                    }

                    for (0..af.num_samples) |i| {
                        const item_start = i * 4;
                        const item_end = item_start + 4;
                        const item_slice = af.channel_data.items[0][item_start..item_end];
                        const item = std.mem.bytesAsValue(f32, item_slice).*;
                        num_samples_collected += 1;

                        sample.max = @max(item, sample.max);
                        sample.min = @min(item, sample.min);

                        if (num_samples_collected % window_size == 0) {
                            self.shared.mutex.lock();
                            defer self.shared.mutex.unlock();
                            try self.shared.samples.append(sample);

                            sample = Sample{
                                .max = -std.math.inf(f32),
                                .min = std.math.inf(f32),
                            };
                        }
                    }
                },
                .video => {
                    continue;
                },
            }
        }

        if (num_samples_collected != 0) {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            try self.shared.samples.append(sample);
        }
    }

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

    fn calculateWindowSize(stream_info: decoder.AudioStreamInfo, runtime_s: f32, target_memory_usage_bytes: usize) usize {
        const audio_mem_usage_f: f32 = @as(f32, @floatFromInt(stream_info.sample_rate)) * runtime_s;
        const audio_mem_usage: usize = @intFromFloat(audio_mem_usage_f);
        if (audio_mem_usage <= target_memory_usage_bytes) {
            return 1;
        }
        // Round up
        return (audio_mem_usage * @sizeOf(Sample) + target_memory_usage_bytes - 1) / target_memory_usage_bytes;
    }
};

const InitData = struct {
    mutex: std.Thread.Mutex,
    samples: std.ArrayList(Sample),
    num_samples: usize,
    // No mutex lock necessary
    shutdown: std.atomic.Value(bool),

    fn deinit(self: *InitData) void {
        self.samples.deinit();
    }
};

alloc: Allocator,
// Owned, but needs stable memory location for init thread
shared: *InitData,
init_thread_handle: std.Thread,
program: c.GLuint = 0,
last_buf_len: usize,
vbo: c.GLuint,
vao: c.GLuint,

const vertex_shader_source: [*c]const u8 = @embedFile("AudioRenderer/vertex.glsl");
const fragment_shader_source: [*c]const u8 = @embedFile("AudioRenderer/fragment.glsl");

pub fn initGl(self: *AudioRenderer, guigl: ?*anyopaque) void {
    const program = gl_helpers.compileProgram(guigl, vertex_shader_source, fragment_shader_source);
    errdefer c.guigl_delete_program(guigl, program);

    self.vbo = c.guigl_create_buffer(guigl);
    self.vao = c.guigl_create_vertex_array(guigl);

    updateVertexBuffer(self, guigl);
    self.program = program;
}

fn updateVertexBuffer(self: *AudioRenderer, guigl: ?*c.GuiGl) void {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    if (self.last_buf_len == self.shared.samples.items.len) {
        return;
    }

    self.last_buf_len = self.shared.samples.items.len;

    var vertices = self.alloc.alloc(f32, self.shared.samples.items.len * 4) catch {
        std.log.err("Failed to allocate vertex buffer for audio data", .{});
        return;
    };
    defer self.alloc.free(vertices);

    const item_len_i: i64 = @intCast(self.shared.num_samples);
    const num_samples_f: f32 = @floatFromInt(self.shared.num_samples);
    for (self.shared.samples.items, 0..) |sample, i_u| {
        const i_i: i64 = @intCast(i_u);
        var x_norm: f32 = @floatFromInt(2 * i_i - item_len_i);
        x_norm /= num_samples_f;
        const vert_idx = i_u * 4;
        vertices[vert_idx] = x_norm;
        vertices[vert_idx + 1] = sample.min;
        vertices[vert_idx + 2] = x_norm;
        vertices[vert_idx + 3] = sample.max;
    }

    c.guigl_bind_vertex_array(guigl, self.vao);
    c.guigl_bind_buffer(guigl, c.GL_ARRAY_BUFFER, self.vbo);
    c.guigl_buffer_data(guigl, c.GL_ARRAY_BUFFER, @intCast(vertices.len * 4), vertices.ptr, c.GL_STATIC_DRAW);
    c.guigl_vertex_attrib_pointer(guigl, 0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * 4, null);
    c.guigl_enable_vertex_attrib_array(guigl, 0);
}

pub fn deinitGl(self: *AudioRenderer, guigl: ?*anyopaque) void {
    c.guigl_delete_buffer(guigl, self.vbo);
    c.guigl_delete_vertex_array(guigl, self.vao);
    c.guigl_delete_program(guigl, self.program);
}

pub fn render(self: *AudioRenderer, guigl: ?*anyopaque, zoom: f32, center_norm: f32) void {
    self.updateVertexBuffer(guigl);

    c.guigl_use_program(guigl, self.program);
    c.guigl_line_width(guigl, 2.0);
    c.guigl_bind_vertex_array(guigl, self.vao);
    c.guigl_uniform_1f(guigl, c.guigl_get_uniform_location(guigl, self.program, "zoom"), zoom);
    c.guigl_uniform_1f(guigl, c.guigl_get_uniform_location(guigl, self.program, "center"), center_norm);
    c.guigl_draw_arrays(guigl, c.GL_LINES, 0, @intCast(self.last_buf_len * 2));
}

pub fn init(alloc: Allocator, path: [:0]const u8) !AudioRenderer {
    const shared = try alloc.create(InitData);
    errdefer shared.deinit();

    shared.* = .{
        .mutex = .{},
        .samples = std.ArrayList(Sample).init(alloc),
        .num_samples = 1,
        .shutdown = std.atomic.Value(bool).init(false),
    };

    const init_thread = try InitThread.init(alloc, path, shared);
    const init_thread_handle = std.Thread.spawn(.{}, InitThread.run_and_consume, .{init_thread}) catch |e| {
        init_thread.deinit();
        return e;
    };

    return .{
        .alloc = alloc,
        .init_thread_handle = init_thread_handle,
        .shared = shared,
        .vbo = 0,
        .vao = 0,
        .last_buf_len = 0,
    };
}

pub fn deinit(self: *AudioRenderer) void {
    self.shared.shutdown.store(true, std.builtin.AtomicOrder.unordered);
    self.init_thread_handle.join();
    self.shared.deinit();
    self.alloc.destroy(self.shared);
}
