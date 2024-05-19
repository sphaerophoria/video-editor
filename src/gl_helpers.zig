const c = @import("c.zig");

pub fn compileProgram(guigl: ?*anyopaque, vertex_shader_source: [*c]const u8, fragment_shader_source: [*c]const u8) c.GLuint {
    const vertex_shader = c.guigl_create_shader(guigl, c.GL_VERTEX_SHADER);
    defer c.guigl_delete_shader(guigl, vertex_shader);
    c.guigl_shader_source(guigl, vertex_shader, &vertex_shader_source);
    c.guigl_compile_shader(guigl, vertex_shader);

    const fragment_shader = c.guigl_create_shader(guigl, c.GL_FRAGMENT_SHADER);
    defer c.guigl_delete_shader(guigl, fragment_shader);
    c.guigl_shader_source(guigl, fragment_shader, &fragment_shader_source);
    c.guigl_compile_shader(guigl, fragment_shader);

    const program = c.guigl_create_program(guigl);
    errdefer c.guigl_delete_program(guigl, program);
    c.guigl_attach_shader(guigl, program, vertex_shader);
    c.guigl_attach_shader(guigl, program, fragment_shader);
    c.guigl_link_program(guigl, program);

    return program;
}
