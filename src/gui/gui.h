#ifndef __GUI_COMMON_H__
#define __GUI_COMMON_H__

#include <GL/gl.h>
#include <stdbool.h>

typedef void FrameRenderer;
typedef void AudioRenderer;
typedef void GuiGl;
typedef void Gui;
typedef void AppState;
typedef void WordTimestampMap;

struct Clip {
    uint64_t id;
    float start;
    float end;
};

enum GuiActionTag {
    gui_action_none,
    gui_action_toggle_pause,
    gui_action_close,
    gui_action_seek,
    gui_action_clip_edit,
    gui_action_clip_add,
    gui_action_clip_remove,
    gui_action_save,
};

struct GuiAction {
    enum GuiActionTag tag;
    union {
        float seek_position;
        struct Clip clip;
        uint64_t id;
    } data;
};

struct AppStateSnapshot {
    bool paused;
    float current_position;
    float total_runtime;
    const struct Clip* clips;
    uint64_t num_clips;
    const char* text;
    uint64_t text_len;
    const uint64_t* text_split_indices;
    uint64_t text_split_indices_len;
};

// GUI interface
Gui* gui_init(AppState* state);
void gui_free(Gui* gui);
void gui_run(Gui* gui, FrameRenderer* frame_renderer, AudioRenderer* audio_renderer, WordTimestampMap* wtm);
struct GuiAction gui_next_action(Gui* gui);
void gui_wait_start(Gui* gui);
void gui_notify_update(Gui* gui);
void gui_close(Gui* gui);

// Gui OpenGL wrappers
// GUI owns window creation, and has to draw widgets to the screen. This means
// that it owns the OpenGL context. If we want to render frames in OpenGL, then
// we have to provide the OpenGL interface
GLuint guigl_create_shader(GuiGl* guigl, GLenum shader_type);
void   guigl_delete_shader(GuiGl* guigl, GLuint shader);
void   guigl_shader_source(GuiGl* guigl, GLuint shader, const GLchar* const* source);
void   guigl_compile_shader(GuiGl* guigl, GLuint shader);
GLuint guigl_create_program(GuiGl* guigl);
void   guigl_use_program(GuiGl* guigl, GLuint program);
void   guigl_delete_program(GuiGl* guigl, GLuint program);
void   guigl_attach_shader(GuiGl* guigl, GLuint program, GLuint shader);
void   guigl_link_program(GuiGl* guigl, GLuint program);
GLuint guigl_gen_texture(GuiGl* guigl);
void   guigl_delete_texture(GuiGl* guigl, GLuint texture);
void   guigl_bind_texture(GuiGl* guigl, GLenum target, GLuint texture);
void   guigl_active_texture(GuiGl* guigl, GLuint texture);
void   guigl_tex_parameter_i(GuiGl* guigl, GLenum target, GLenum name, GLint param);
void   guigl_tex_image_2d(GuiGl* guigl, GLenum target, GLint level, GLint internal_format, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum typ, const void * pixels);
void   guigl_uniform_1i(GuiGl* guigl, GLint loc, GLint val);
void   guigl_uniform_1f(GuiGl* guigl, GLint loc, GLfloat val);
GLint  guigl_get_uniform_location(GuiGl* guigl, GLuint program, const GLchar * name);
void   guigl_draw_arrays(GuiGl* guigl, GLenum mode, GLint first, GLsizei count);
void   guigl_clear_color(GuiGl* guigl, GLfloat r, GLfloat g, GLfloat b, GLfloat a);
void   guigl_clear(GuiGl* guigl, GLbitfield mask);
void   guigl_line_width(GuiGl* guigl, GLfloat width);

GLuint guigl_create_buffer(GuiGl* guigl);
void   guigl_delete_buffer(GuiGl* guigl, GLuint buffer_id);
void   guigl_bind_buffer(GuiGl* guigl, GLenum target, GLuint buffer_id);
void   guigl_buffer_data(GuiGl* guigl, GLenum target, GLsizeiptr size, const void * data, GLenum usage);
GLuint guigl_create_vertex_array(GuiGl* guigl);
void   guigl_delete_vertex_array(GuiGl* guigl, GLuint array_id);
void   guigl_bind_vertex_array(GuiGl* guigl, GLuint array_id);
void   guigl_vertex_attrib_pointer(GuiGl* guigl, GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void * pointer);
void   guigl_enable_vertex_attrib_array(GuiGl* guigl, GLuint index);

// Zig interface
void framerenderer_init_gl(FrameRenderer* renderer, GuiGl* guigl);
void framerenderer_render(FrameRenderer* renderer, float width, float height, GuiGl* guigl);
void framerenderer_deinit_gl(FrameRenderer* renderer, GuiGl* guigl);

void audiorenderer_init_gl(AudioRenderer* renderer, GuiGl* guigl);
void audiorenderer_render(AudioRenderer* renderer, GuiGl* guigl, float zoom, float center_norm);
void audiorenderer_deinit_gl(AudioRenderer* renderer, GuiGl* guigl);

float wtm_get_time(WordTimestampMap* m, uint64_t char_pos);
uint64_t wtm_get_char_pos(WordTimestampMap* m, float pts);

struct AppStateSnapshot appstate_snapshot(AppState* app);
void appstate_deinit(AppState* app, const struct AppStateSnapshot* snapshot);

#endif // __GUI_H__
