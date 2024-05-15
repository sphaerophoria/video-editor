use crate::c_bindings::*;
use eframe::glow::{self, HasContext};
use std::ffi::c_void;

#[no_mangle]
unsafe extern "C" fn guigl_create_shader(context: *const glow::Context, v: GLenum) -> GLuint {
    match (*context).create_shader(v) {
        Ok(v) => v.0.into(),
        Err(e) => {
            eprintln!("Failed to create shader: {}", e);
            GLuint::MAX
        }
    }
}

#[no_mangle]
unsafe extern "C" fn guigl_delete_shader(context: *const glow::Context, shader: GLuint) {
    (*context).delete_shader(glow::NativeShader(shader.try_into().unwrap()));
}

#[no_mangle]
unsafe extern "C" fn guigl_shader_source(
    context: *const glow::Context,
    shader: GLuint,
    s: *const *const GLchar,
) {
    let c_str = std::ffi::CStr::from_ptr(*s);
    (*context).shader_source(
        glow::NativeShader(shader.try_into().unwrap()),
        c_str.to_str().unwrap(),
    );
}

#[no_mangle]
unsafe extern "C" fn guigl_compile_shader(context: *const glow::Context, shader: GLuint) {
    (*context).compile_shader(glow::NativeShader(shader.try_into().unwrap()));
}

#[no_mangle]
unsafe extern "C" fn guigl_create_program(context: *const glow::Context) -> GLuint {
    match (*context).create_program() {
        Ok(v) => v.0.into(),
        Err(e) => {
            eprintln!("Failed to create program: {}", e);
            GLuint::MAX
        }
    }
}

#[no_mangle]
unsafe extern "C" fn guigl_delete_program(context: *const glow::Context, program: GLuint) {
    (*context).delete_program(glow::NativeProgram(program.try_into().unwrap()));
}

#[no_mangle]
unsafe extern "C" fn guigl_attach_shader(
    context: *const glow::Context,
    program: GLuint,
    shader: GLuint,
) {
    (*context).attach_shader(
        glow::NativeProgram(program.try_into().unwrap()),
        glow::NativeShader(shader.try_into().unwrap()),
    );
}

#[no_mangle]
unsafe extern "C" fn guigl_link_program(context: *const glow::Context, program: GLuint) {
    (*context).link_program(glow::NativeProgram(program.try_into().unwrap()));
}

#[no_mangle]
unsafe extern "C" fn guigl_gen_texture(context: *const glow::Context) -> GLuint {
    match (*context).create_texture() {
        Ok(v) => v.0.into(),
        Err(e) => {
            eprintln!("Failed to create texture: {}", e);
            GLuint::MAX
        }
    }
}

#[no_mangle]
unsafe extern "C" fn guigl_bind_texture(
    context: *const glow::Context,
    target: GLenum,
    texture: GLuint,
) {
    let texture = match texture {
        0 => None,
        v => Some(glow::NativeTexture(v.try_into().unwrap())),
    };
    (*context).bind_texture(target, texture);
}

#[no_mangle]
unsafe extern "C" fn guigl_tex_parameter_i(
    context: *const glow::Context,
    target: GLenum,
    pname: GLenum,
    param: GLint,
) {
    (*context).tex_parameter_i32(target, pname, param);
}

#[no_mangle]
unsafe extern "C" fn guigl_active_texture(context: *const glow::Context, texture: GLuint) {
    (*context).active_texture(texture);
}

#[no_mangle]
unsafe extern "C" fn guigl_delete_texture(context: *const glow::Context, texture: GLuint) {
    (*context).delete_texture(glow::NativeTexture(texture.try_into().unwrap()));
}

#[no_mangle]
unsafe extern "C" fn guigl_draw_arrays(
    context: *const glow::Context,
    mode: GLenum,
    first: GLint,
    count: GLsizei,
) {
    (*context).draw_arrays(mode, first, count);
}

#[no_mangle]
unsafe extern "C" fn guigl_uniform_1i(context: *const glow::Context, loc: GLint, val: GLint) {
    let loc = glow::NativeUniformLocation(loc.try_into().unwrap());
    (*context).uniform_1_i32(Some(&loc), val);
}

#[no_mangle]
unsafe extern "C" fn guigl_uniform_1f(context: *const glow::Context, loc: GLint, val: GLfloat) {
    let loc = glow::NativeUniformLocation(loc.try_into().unwrap());
    (*context).uniform_1_f32(Some(&loc), val);
}

#[no_mangle]
unsafe extern "C" fn guigl_get_uniform_location(
    context: *const glow::Context,
    program: GLuint,
    name: *const GLchar,
) -> GLint {
    let c_name = std::ffi::CStr::from_ptr(name);
    let ret = (*context).get_uniform_location(
        glow::NativeProgram(program.try_into().unwrap()),
        c_name.to_str().unwrap(),
    );
    match ret {
        Some(v) => v.0 as GLint,
        None => {
            eprintln!("Failed to get uniform location");
            -1
        }
    }
}

#[no_mangle]
unsafe extern "C" fn guigl_tex_image_2d(
    context: *const glow::Context,
    target: GLenum,
    level: GLint,
    internal_format: GLint,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
    format: GLenum,
    ty: GLenum,
    pixels: *const c_void,
) {
    let pixels: *const u8 = pixels as *const u8;
    let pixel_size = match ty {
        glow::UNSIGNED_BYTE => 1,
        _ => {
            unimplemented!();
        }
    };

    let pixels = std::slice::from_raw_parts(
        pixels,
        width as usize * height as usize * pixel_size as usize,
    );
    (*context).tex_image_2d(
        target,
        level,
        internal_format,
        width,
        height,
        border,
        format,
        ty,
        Some(pixels),
    );
}

#[no_mangle]
unsafe extern "C" fn guigl_use_program(context: *const glow::Context, program: GLuint) {
    (*context).use_program(Some(glow::NativeProgram(program.try_into().unwrap())));
}
