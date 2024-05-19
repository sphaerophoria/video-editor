#include <gui.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum GuiState {
  kGuiStateFinished,
  kGuiStateTogglePause,
  kGuiStateSeek,
  kGuiStateNormal,
};

#define MAX_ALLOCATIONS 100
struct GuiImpl {
  pthread_mutex_t state_mutex;
  enum GuiState state;
  float seek_pos;
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
  (void)shader_type;
  return impl_alloc(guigl);
}

void guigl_delete_shader(GuiGl* guigl, GLuint shader) {
  impl_free(guigl, shader);
}

void guigl_shader_source(GuiGl* guigl, GLuint shader,
                         GLchar const* const* source) {
  (void)guigl;
  (void)shader;
  (void)source;
}

void guigl_compile_shader(GuiGl* guigl, GLuint shader) {
  (void)guigl;
  (void)shader;
}

GLuint guigl_create_program(GuiGl* guigl) { return impl_alloc(guigl); }

void guigl_use_program(GuiGl* guigl, GLuint program) {
  (void)guigl;
  (void)program;
}

void guigl_delete_program(GuiGl* guigl, GLuint program) {
  impl_free(guigl, program);
}

void guigl_attach_shader(GuiGl* guigl, GLuint program, GLuint shader) {
  (void)guigl;
  (void)program;
  (void)shader;
}

void guigl_link_program(GuiGl* guigl, GLuint program) {
  (void)guigl;
  (void)program;
}

GLuint guigl_gen_texture(GuiGl* guigl) { return impl_alloc(guigl); }

void guigl_delete_texture(GuiGl* guigl, GLuint texture) {
  impl_free(guigl, texture);
}

void guigl_bind_texture(GuiGl* guigl, GLenum target, GLuint texture) {
  (void)guigl;
  (void)target;
  (void)texture;
}

void guigl_active_texture(GuiGl* guigl, GLuint texture) {
  (void)guigl;
  (void)texture;
}

void guigl_tex_parameter_i(GuiGl* guigl, GLenum target, GLenum name,
                           GLint param) {
  (void)guigl;
  (void)target;
  (void)name;
  (void)param;
}

void guigl_tex_image_2d(GuiGl* guigl, GLenum target, GLint level,
                        GLint internal_format, GLsizei width, GLsizei height,
                        GLint border, GLenum format, GLenum typ,
                        void const* pixels) {
  (void)guigl;
  (void)target;
  (void)level;
  (void)internal_format;
  (void)width;
  (void)height;
  (void)border;
  (void)format;
  (void)typ;
  (void)pixels;
}

void guigl_uniform_1i(GuiGl* guigl, GLint loc, GLint val) {
  (void)guigl;
  (void)loc;
  (void)val;
}

void guigl_uniform_1f(GuiGl* guigl, GLint loc, GLfloat val) {
  (void)guigl;
  (void)loc;
  (void)val;
}

GLint guigl_get_uniform_location(GuiGl* guigl, GLuint program,
                                 GLchar const* name) {
  (void)guigl;
  (void)program;
  (void)name;
  return 0;
}

void guigl_draw_arrays(GuiGl* guigl, GLenum mode, GLint first, GLsizei count) {
  (void)guigl;
  (void)mode;
  (void)first;
  (void)count;
}

// GUI interface
Gui* gui_init(AppState* state) {
  (void)state;
  struct GuiImpl* impl = malloc(sizeof(struct GuiImpl));
  pthread_mutex_init(&impl->state_mutex, NULL);
  impl->state = kGuiStateNormal;
  impl->allocation_id = 0;
  memset(impl->allocations, 0, MAX_ALLOCATIONS);

  return impl;
}

void gui_free(Gui* gui) { free(gui); }

void gui_run(Gui* gui, Renderer* renderer) {
  struct GuiImpl* impl = gui;
  framerenderer_init_gl(renderer, gui);
  for (int i = 0; i < 60 * 3; ++i) {
    framerenderer_render(renderer, 800.0, 600.0, gui);
    if (i % 60 == 15) {
      pthread_mutex_lock(&impl->state_mutex);
      impl->state = kGuiStateSeek;
      // Looking for some combo of seeking both forwards and backwards
      impl->seek_pos = i % 13;
      pthread_mutex_unlock(&impl->state_mutex);
    } else if (i % 30 == 0) {
      pthread_mutex_lock(&impl->state_mutex);
      impl->state = kGuiStateTogglePause;
      pthread_mutex_unlock(&impl->state_mutex);
    }
    // 60fps
    usleep(16666);
  }
  framerenderer_deinit_gl(renderer, gui);

  pthread_mutex_lock(&impl->state_mutex);
  impl->state = kGuiStateFinished;
  pthread_mutex_unlock(&impl->state_mutex);
}

struct GuiAction gui_next_action(Gui* gui) {
  struct GuiImpl* impl = gui;
  pthread_mutex_lock(&impl->state_mutex);
  struct GuiAction ret = {0};

  switch (impl->state) {
    case kGuiStateNormal: {
      ret.tag = gui_action_none;
      break;
    }
    case kGuiStateTogglePause: {
      impl->state = kGuiStateNormal;
      ret.tag = gui_action_toggle_pause;
      break;
    }
    case kGuiStateSeek: {
      impl->state = kGuiStateNormal;
      ret.tag = gui_action_seek;
      ret.seek_position = impl->seek_pos;
      break;
    }
    case kGuiStateFinished: {
      ret.tag = gui_action_close;
      break;
    }
    default: {
      fprintf(stderr, "gui in invalid state\n");
      exit(1);
    }
  }

  pthread_mutex_unlock(&impl->state_mutex);
  return ret;
}

void gui_wait_start(Gui* gui) { (void)gui; }

void gui_notify_update(Gui* gui) { (void)gui; }

void gui_close(Gui* gui) { (void)gui; }
