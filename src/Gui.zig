const std = @import("std");
const c = @import("c.zig");
const decoder = @import("decoder.zig");
const VideoFrame = decoder.VideoFrame;

y_texture: c.GLuint,
u_texture: c.GLuint,
v_texture: c.GLuint,
program: c.GLuint,
window: *c.GLFWwindow,

const Self = @This();

const vertex_shader_source: [*c]const u8 = @embedFile("Gui/vertex.glsl");
const fragment_shader_source: [*c]const u8 = @embedFile("Gui/fragment.glsl");

const Error = error{
    Initialization,
};

pub fn init() Error!Self {
    if (c.glfwInit() == c.GLFW_FALSE) {
        std.log.err("failed to init glfw", .{});
        return error.Initialization;
    }

    errdefer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(errorCallback);

    const window = c.glfwCreateWindow(640, 480, "My Title", null, null) orelse {
        std.log.err("failed to create glfw window", .{});
        return error.Initialization;
    };

    errdefer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);
    if (c.gladLoadGL() == 0) {
        std.log.err("failed to init glad", .{});
        return error.Initialization;
    }

    c.glfwSwapInterval(1);

    c.glEnable(c.GL_DEBUG_OUTPUT);
    c.glDebugMessageCallback(glDebugCallback, null);

    const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
    defer c.glDeleteShader(vertex_shader);
    c.glShaderSource(vertex_shader, 1, &vertex_shader_source, null);
    c.glCompileShader(vertex_shader);

    const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    defer c.glDeleteShader(fragment_shader);
    c.glShaderSource(fragment_shader, 1, &fragment_shader_source, null);
    c.glCompileShader(fragment_shader);

    const program = c.glCreateProgram();
    errdefer c.glDeleteProgram(program);
    c.glAttachShader(program, vertex_shader);
    c.glAttachShader(program, fragment_shader);
    c.glLinkProgram(program);

    c.glClearColor(0.0, 0.0, 1.0, 1.0);

    const y_texture = makeTexture();
    errdefer c.glDeleteTextures(1, &y_texture);

    const u_texture = makeTexture();
    errdefer c.glDeleteTextures(1, &u_texture);

    const v_texture = makeTexture();
    errdefer c.glDeleteTextures(1, &v_texture);

    return .{
        .y_texture = y_texture,
        .u_texture = u_texture,
        .v_texture = v_texture,
        .program = program,
        .window = window,
    };
}

pub fn deinit(self: *Self) void {
    c.glDeleteTextures(1, &self.y_texture);
    c.glDeleteTextures(1, &self.u_texture);
    c.glDeleteTextures(1, &self.v_texture);
    c.glDeleteProgram(self.program);
    c.glfwDestroyWindow(self.window);
    c.glfwTerminate();
}

pub fn swapFrame(self: *Self, frame: VideoFrame) void {
    c.glBindTexture(c.GL_TEXTURE_2D, self.y_texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(frame.stride), @intCast(frame.height), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.y.ptr);

    c.glBindTexture(c.GL_TEXTURE_2D, self.u_texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(@divTrunc(frame.stride, 2)), @intCast(@divTrunc(frame.height, 2)), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.u.ptr);

    c.glBindTexture(c.GL_TEXTURE_2D, self.v_texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(@divTrunc(frame.stride, 2)), @intCast(@divTrunc(frame.height, 2)), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, frame.v.ptr);
}

pub fn shouldClose(self: *const Self) bool {
    return c.glfwWindowShouldClose(self.window) != 0;
}

pub fn setClose(self: *Self) void {
    c.glfwSetWindowShouldClose(self.window, 1);
}

pub fn render(self: *Self) void {
    var width: c_int = undefined;
    var height: c_int = undefined;

    c.glfwGetFramebufferSize(self.window, &width, &height);
    c.glViewport(0, 0, width, height);

    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glUseProgram(self.program);

    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, self.y_texture);

    c.glActiveTexture(c.GL_TEXTURE1);
    c.glBindTexture(c.GL_TEXTURE_2D, self.u_texture);

    c.glActiveTexture(c.GL_TEXTURE2);
    c.glBindTexture(c.GL_TEXTURE_2D, self.v_texture);

    c.glUniform1i(c.glGetUniformLocation(self.program, "y_tex"), 0);
    c.glUniform1i(c.glGetUniformLocation(self.program, "u_tex"), 1);
    c.glUniform1i(c.glGetUniformLocation(self.program, "v_tex"), 2);

    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

    c.glfwSwapBuffers(self.window);
}

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

fn makeTexture() c.GLuint {
    var texture: c.GLuint = undefined;
    c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    // set the texture wrapping/filtering options (on the currently bound texture object)
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    return texture;
}
