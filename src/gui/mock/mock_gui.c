#include <gui.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

struct GuiGlImpl {
	unsigned int allocation_id;
	void* allocations[100];
};

static GLuint impl_alloc(struct GuiGlImpl* impl) {
	impl->allocations[impl->allocation_id] = malloc(1);
	return impl->allocation_id++;
}

static void impl_free(struct GuiGlImpl* impl, GLuint id) {
	free(impl->allocations[id]);
}

GLuint guigl_create_shader(GuiGl* guigl, GLenum shader_type) {
	return impl_alloc(guigl);
}

void   guigl_delete_shader(GuiGl* guigl, GLuint shader) {
	impl_free(guigl, shader);
}
void   guigl_shader_source(GuiGl* guigl, GLuint shader, const GLchar* const* source) {}
void   guigl_compile_shader(GuiGl* guigl, GLuint shader) {}
GLuint guigl_create_program(GuiGl* guigl) {
	return impl_alloc(guigl);
}
void   guigl_use_program(GuiGl* guigl, GLuint program) {}
void   guigl_delete_program(GuiGl* guigl, GLuint program) {
	impl_free(guigl, program);
}
void   guigl_attach_shader(GuiGl* guigl, GLuint program, GLuint shader) {}
void   guigl_link_program(GuiGl* guigl, GLuint program) {}
GLuint guigl_gen_texture(GuiGl* guigl) {
	return impl_alloc(guigl);
}
void   guigl_delete_texture(GuiGl* guigl, GLuint texture) {
	impl_free(guigl, texture);
}
void   guigl_bind_texture(GuiGl* guigl, GLenum target, GLuint texture) {}
void   guigl_active_texture(GuiGl* guigl, GLuint texture) {}
void   guigl_tex_parameter_i(GuiGl* guigl, GLenum target, GLenum name, GLint param) {}
void   guigl_tex_image_2d(GuiGl* guigl, GLenum target, GLint level, GLint internal_format, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum typ, const void * pixels) {}
void   guigl_uniform_1i(GuiGl* guigl, GLint loc, GLint val) {}
void   guigl_uniform_1f(GuiGl* guigl, GLint loc, GLfloat val) {}
GLint  guigl_get_uniform_location(GuiGl* guigl, GLuint program, const GLchar * name) {
	return 0;
}
void   guigl_draw_arrays(GuiGl* guigl, GLenum mode, GLint first, GLsizei count) {}


void gui_run(Renderer* renderer) {
	struct GuiGlImpl impl = {
		.allocation_id = 0,
		.allocations = {0},
	};
	framerenderer_init_gl(renderer, &impl);
	for (int i = 0; i < 3; ++i)  {
		framerenderer_render(renderer, 800.0, 600.0, &impl);
		sleep(1);
	}
	framerenderer_deinit_gl(renderer, &impl);
}
