const std = @import("std");
const c = @import("c.zig");
const decoder = @import("decoder.zig");
const gl_helpers = @import("gl_helpers.zig");
const Allocator = std.mem.Allocator;
const VideoFrame = decoder.VideoFrame;

pub const SharedData = struct {
    mutex: std.Thread.Mutex = .{},
    img: ?decoder.VideoFrame = null,

    pub fn swapFrame(self: *SharedData, frame: decoder.VideoFrame) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.img) |*img| {
            img.deinit();
        }
        self.img = frame;
    }

    pub fn consumeFrame(self: *SharedData) ?decoder.VideoFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        defer self.img = null;
        return self.img;
    }

    pub fn deinit(self: *SharedData) void {
        if (self.img) |*img| {
            img.deinit();
        }
    }
};

shared: *SharedData,

y_texture: c.GLuint = 0,
u_texture: c.GLuint = 0,
v_texture: c.GLuint = 0,
width_ratio: f32 = 1.0,
image_aspect_ratio: f32 = 1.0,
program: c.GLuint = 0,

const Self = @This();

const vertex_shader_source: [*c]const u8 = @embedFile("FrameRenderer/vertex.glsl");
const fragment_shader_source: [*c]const u8 = @embedFile("FrameRenderer/fragment.glsl");

const Error = error{
    Initialization,
};

pub export fn framerenderer_render(self: *Self, width: f32, height: f32, guigl: ?*anyopaque) void {
    self.render(width, height, guigl);
}

pub export fn framerenderer_init_gl(self: *Self, guigl: ?*anyopaque) void {
    self.initGl(guigl);
}

pub export fn framerenderer_deinit_gl(self: *Self, guigl: ?*anyopaque) void {
    self.deinitGl(guigl);
}

pub fn init(shared: *SharedData) Self {
    return .{
        .shared = shared,
    };
}

pub fn initGl(self: *Self, guigl: ?*anyopaque) void {
    const program = gl_helpers.compileProgram(guigl, vertex_shader_source, fragment_shader_source);
    errdefer c.guigl_delete_program(guigl, program);

    const y_texture = makeTexture(guigl);
    errdefer c.guigl_delete_texture(guigl, y_texture);

    const u_texture = makeTexture(guigl);
    errdefer c.guigl_delete_texture(guigl, u_texture);

    const v_texture = makeTexture(guigl);
    errdefer c.guigl_delete_texture(guigl, v_texture);

    self.y_texture = y_texture;
    self.u_texture = u_texture;
    self.v_texture = v_texture;
    self.width_ratio = 1.0;
    self.image_aspect_ratio = 1.0;
    self.program = program;
}

pub fn deinitGl(self: *Self, guigl: ?*anyopaque) void {
    c.guigl_delete_texture(guigl, self.y_texture);
    c.guigl_delete_texture(guigl, self.u_texture);
    c.guigl_delete_texture(guigl, self.v_texture);
    c.guigl_delete_program(guigl, self.program);
}

pub fn render(self: *Self, width: f32, height: f32, guigl: ?*anyopaque) void {
    self.updateTextures(guigl);

    const aspect_ratio_ratio = width / height / self.image_aspect_ratio;

    c.guigl_use_program(guigl, self.program);

    c.guigl_active_texture(guigl, c.GL_TEXTURE0);
    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.y_texture);

    c.guigl_active_texture(guigl, c.GL_TEXTURE1);
    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.u_texture);

    c.guigl_active_texture(guigl, c.GL_TEXTURE2);
    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.v_texture);

    c.guigl_uniform_1i(guigl, c.guigl_get_uniform_location(guigl, self.program, "y_tex"), 0);
    c.guigl_uniform_1i(guigl, c.guigl_get_uniform_location(guigl, self.program, "u_tex"), 1);
    c.guigl_uniform_1i(guigl, c.guigl_get_uniform_location(guigl, self.program, "v_tex"), 2);
    c.guigl_uniform_1f(guigl, c.guigl_get_uniform_location(guigl, self.program, "width_ratio"), self.width_ratio);
    c.guigl_uniform_1f(guigl, c.guigl_get_uniform_location(guigl, self.program, "aspect_ratio_ratio"), aspect_ratio_ratio);

    c.guigl_draw_arrays(guigl, c.GL_TRIANGLE_STRIP, 0, 4);
}

fn updateTextures(self: *Self, guigl: ?*anyopaque) void {
    var frame: decoder.VideoFrame = self.shared.consumeFrame() orelse {
        return;
    };
    defer frame.deinit();

    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.y_texture);
    c.guigl_tex_image_2d(guigl, c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(frame.stride), @intCast(frame.height), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.y.ptr);

    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.u_texture);
    c.guigl_tex_image_2d(guigl, c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(@divTrunc(frame.stride, 2)), @intCast(@divTrunc(frame.height, 2)), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.u.ptr);

    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, self.v_texture);
    c.guigl_tex_image_2d(guigl, c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(@divTrunc(frame.stride, 2)), @intCast(@divTrunc(frame.height, 2)), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.v.ptr);

    self.width_ratio = @floatFromInt(frame.width);
    self.width_ratio /= @floatFromInt(frame.stride);

    self.image_aspect_ratio = @floatFromInt(frame.width);
    self.image_aspect_ratio /= @floatFromInt(frame.height);
}

fn makeTexture(guigl: ?*anyopaque) c.GLuint {
    const texture = c.guigl_gen_texture(guigl);
    c.guigl_bind_texture(guigl, c.GL_TEXTURE_2D, texture);
    // set the texture wrapping/filtering options (on the currently bound texture object)
    c.guigl_tex_parameter_i(guigl, c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
    c.guigl_tex_parameter_i(guigl, c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
    c.guigl_tex_parameter_i(guigl, c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.guigl_tex_parameter_i(guigl, c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    return texture;
}
