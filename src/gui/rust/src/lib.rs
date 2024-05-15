use eframe::{egui, egui_glow, glow};

use std::ffi::c_void;

mod c_bindings;
mod gl_exports;

#[derive(Clone)]
struct RendererPtr(*mut c_void);
unsafe impl Send for RendererPtr {}
unsafe impl Sync for RendererPtr {}

#[no_mangle]
pub extern "C" fn gui_run(renderer: *mut c_void) {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([350.0, 380.0]),
        multisampling: 4,
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };

    let renderer = RendererPtr(renderer);
    eframe::run_native(
        "Custom 3D painting in eframe using glow",
        options,
        Box::new(move |cc| Box::new(Gui::new(cc, renderer))),
    )
    .unwrap();
}

struct Gui {
    renderer: RendererPtr,
}

impl Gui {
    fn new(cc: &eframe::CreationContext<'_>, renderer: RendererPtr) -> Self {
        let gl = cc
            .gl
            .as_ref()
            .expect("You need to run eframe with the glow backend");

        unsafe {
            let userdata: *const glow::Context = &**gl;
            c_bindings::framerenderer_init_gl(renderer.0, userdata as *mut c_void);
        }
        Self { renderer }
    }
}

impl eframe::App for Gui {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut frame = egui::Frame::central_panel(&ctx.style());
        frame.inner_margin = egui::Margin::same(0.0);
        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
            let rect = ui.max_rect();

            let renderer = self.renderer.clone();

            let callback = egui::PaintCallback {
                rect,
                callback: std::sync::Arc::new(egui_glow::CallbackFn::new(
                    move |_info, painter| {
                        let renderer = &renderer;
                        unsafe {
                            let userdata: *const glow::Context = &**painter.gl();
                            c_bindings::framerenderer_render(renderer.0, rect.width(), rect.height(), userdata as *mut c_void);
                        }
                    },
                )),
            };
            ui.painter().add(callback);
        });
    }

    fn on_exit(&mut self, gl: Option<&glow::Context>) {
        unsafe {
            let gl = gl.unwrap();
            let userdata: *const glow::Context = gl;
            c_bindings::framerenderer_deinit_gl(self.renderer.0, userdata as *mut c_void);
        }
    }
}
