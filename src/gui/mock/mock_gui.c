#include <gui.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_ALLOCATIONS 100
struct GuiImpl {
  pthread_mutex_t trigger_action_mutex;
  int trigger_action;
  int next_action_id;
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

void guigl_line_width(GuiGl* guigl, GLfloat width) {
  (void)guigl;
  (void)width;
}

GLuint guigl_create_buffer(GuiGl* guigl) { return impl_alloc(guigl); }

void guigl_delete_buffer(GuiGl* guigl, GLuint buffer_id) {
  impl_free(guigl, buffer_id);
}

void guigl_bind_buffer(GuiGl* guigl, GLenum target, GLuint buffer_id) {
  (void)guigl;
  (void)target;
  (void)buffer_id;
}
void guigl_buffer_data(GuiGl* guigl, GLenum target, GLsizeiptr size,
                       void const* data, GLenum usage) {
  (void)guigl;
  (void)target;
  (void)size;
  (void)data;
  (void)usage;
}

GLuint guigl_create_vertex_array(GuiGl* guigl) { return impl_alloc(guigl); }

void guigl_delete_vertex_array(GuiGl* guigl, GLuint array_id) {
  impl_free(guigl, array_id);
}

void guigl_bind_vertex_array(GuiGl* guigl, GLuint array_id) {
  (void)guigl;
  (void)array_id;
}

void guigl_vertex_attrib_pointer(GuiGl* guigl, GLuint index, GLint size,
                                 GLenum type, GLboolean normalized,
                                 GLsizei stride, void const* pointer) {
  (void)guigl;
  (void)index;
  (void)size;
  (void)type;
  (void)normalized;
  (void)stride;
  (void)pointer;
}

void guigl_enable_vertex_attrib_array(GuiGl* guigl, GLuint index) {
  (void)guigl;
  (void)index;
}

// GUI interface
Gui* gui_init(AppState* state) {
  (void)state;
  struct GuiImpl* impl = malloc(sizeof(struct GuiImpl));
  pthread_mutex_init(&impl->trigger_action_mutex, NULL);
  impl->allocation_id = 0;
  impl->trigger_action = -1;
  impl->next_action_id = 0;
  memset(impl->allocations, 0, MAX_ALLOCATIONS);

  return impl;
}

void gui_free(Gui* gui) { free(gui); }

struct TimedGuiAction {
  int i;
  struct GuiAction action;
};

#define NUM_GUI_ACTIONS 9
#define NUM_ITERS (60 * 3)
const struct TimedGuiAction kGuiActions[NUM_GUI_ACTIONS] = {
    {.i = 0, .action = {.tag = gui_action_clip_add, .data = {.clip = {0}}}},
    {.i = 15,
     .action =
         {
             .tag = gui_action_toggle_pause,
         }},
    {.i = 18,
     .action = {.tag = gui_action_seek, .data = {.seek_position = 5.0F}}},
    {.i = 30,
     .action =
         {
             .tag = gui_action_toggle_pause,
         }},
    {.i = 70,
     .action = {.tag = gui_action_seek, .data = {.seek_position = 0.0F}}},
    {.i = 95,
     .action = {.tag = gui_action_clip_edit,
                .data = {.clip = {.id = 0, .start = 0, .end = 5}}}},
    {.i = 100, .action = {.tag = gui_action_save}},
    {.i = 105,
     .action = {.tag = gui_action_clip_remove, .data = {.seek_position = 2}}},
    {.i = NUM_ITERS - 1,
     .action =
         {
             .tag = gui_action_close,
         }},
};

void gui_run(Gui* gui, FrameRenderer* frame_renderer,
             AudioRenderer* audio_renderer, WordTimestampMap* wtm) {
  (void)wtm;
  struct GuiImpl* impl = gui;
  framerenderer_init_gl(frame_renderer, gui);
  audiorenderer_init_gl(audio_renderer, gui);
  for (int i = 0; i < NUM_ITERS; ++i) {
    framerenderer_render(frame_renderer, 800.0, 600.0, gui);
    audiorenderer_render(audio_renderer, gui, 1.0, 0.5);

    if (impl->next_action_id < NUM_GUI_ACTIONS &&
        i == kGuiActions[impl->next_action_id].i) {
      pthread_mutex_lock(&impl->trigger_action_mutex);
      impl->trigger_action = impl->next_action_id;
      pthread_mutex_unlock(&impl->trigger_action_mutex);
      impl->next_action_id += 1;
    }

    // 60fps
    usleep(16666);
  }
  audiorenderer_deinit_gl(audio_renderer, gui);
  framerenderer_deinit_gl(frame_renderer, gui);
}

struct GuiAction gui_next_action(Gui* gui) {
  struct GuiImpl* impl = gui;
  pthread_mutex_lock(&impl->trigger_action_mutex);
  struct GuiAction ret = {0};

  if (impl->trigger_action >= 0) {
    ret = kGuiActions[impl->trigger_action].action;
    impl->trigger_action = -1;
  }

  pthread_mutex_unlock(&impl->trigger_action_mutex);
  return ret;
}

void gui_wait_start(Gui* gui) { (void)gui; }

void gui_notify_update(Gui* gui) { (void)gui; }

void gui_close(Gui* gui) { (void)gui; }
