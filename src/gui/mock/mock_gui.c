#include <gui.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_ALLOCATIONS 100
struct GuiImpl {
  bool finished;
  unsigned int allocation_id;
  void* allocations[MAX_ALLOCATIONS];
};

static GLuint impl_alloc(struct GuiImpl* impl) {
  impl->allocations[impl->allocation_id] = malloc(1);
  return impl->allocation_id++;
}

static void impl_free(struct GuiImpl* impl, GLuint id) {
  free(impl->allocations[id]);
}

GLuint guigl_create_shader(GuiGl* guigl, GLenum shader_type) {
  return impl_alloc(guigl);
}

void guigl_delete_shader(GuiGl* guigl, GLuint shader) {
  impl_free(guigl, shader);
}
void guigl_shader_source(GuiGl* guigl, GLuint shader,
                         GLchar const* const* source) {}
void guigl_compile_shader(GuiGl* guigl, GLuint shader) {}
GLuint guigl_create_program(GuiGl* guigl) { return impl_alloc(guigl); }
void guigl_use_program(GuiGl* guigl, GLuint program) {}
void guigl_delete_program(GuiGl* guigl, GLuint program) {
  impl_free(guigl, program);
}
void guigl_attach_shader(GuiGl* guigl, GLuint program, GLuint shader) {}
void guigl_link_program(GuiGl* guigl, GLuint program) {}
GLuint guigl_gen_texture(GuiGl* guigl) { return impl_alloc(guigl); }
void guigl_delete_texture(GuiGl* guigl, GLuint texture) {
  impl_free(guigl, texture);
}
void guigl_bind_texture(GuiGl* guigl, GLenum target, GLuint texture) {}
void guigl_active_texture(GuiGl* guigl, GLuint texture) {}
void guigl_tex_parameter_i(GuiGl* guigl, GLenum target, GLenum name,
                           GLint param) {}
void guigl_tex_image_2d(GuiGl* guigl, GLenum target, GLint level,
                        GLint internal_format, GLsizei width, GLsizei height,
                        GLint border, GLenum format, GLenum typ,
                        void const* pixels) {}
void guigl_uniform_1i(GuiGl* guigl, GLint loc, GLint val) {}
void guigl_uniform_1f(GuiGl* guigl, GLint loc, GLfloat val) {}
GLint guigl_get_uniform_location(GuiGl* guigl, GLuint program,
                                 GLchar const* name) {
  return 0;
}
void guigl_draw_arrays(GuiGl* guigl, GLenum mode, GLint first, GLsizei count) {}

// GUI interface
Gui* gui_init(AppState* state) {
  struct GuiImpl* impl = malloc(sizeof(struct GuiImpl));
  impl->finished = false;
  impl->allocation_id = 0;
  memset(impl->allocations, 0, MAX_ALLOCATIONS);

  return impl;
}

void gui_free(Gui* gui) { free(gui); }

void gui_run(Gui* gui, Renderer* renderer) {
  struct GuiImpl* impl = gui;
  framerenderer_init_gl(renderer, gui);
  for (int i = 0; i < 3; ++i) {
    framerenderer_render(renderer, 800.0, 600.0, gui);
    sleep(1);
  }
  framerenderer_deinit_gl(renderer, gui);
  impl->finished = true;
}

enum GuiAction gui_next_action(Gui* gui) {
  struct GuiImpl* impl = gui;
  if (impl->finished) {
    return gui_action_close;
  } else {
    return gui_action_none;
  }
}

void gui_wait_start(Gui* gui) {}
void gui_notify_update(Gui* gui) {}
void gui_close(Gui* gui) {}
