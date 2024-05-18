use eframe::{egui, egui_glow, glow};

use std::{
    ffi::c_void,
    sync::{
        mpsc::{self, Receiver, Sender},
        Condvar, Mutex,
    },
};

mod c_bindings;
mod gl_exports;

#[derive(Clone)]
struct RendererPtr(*mut c_void);
unsafe impl Send for RendererPtr {}
unsafe impl Sync for RendererPtr {}

pub struct GuiInner {
    ctx: Option<egui::Context>,
    action_rx: Receiver<c_bindings::GuiAction>,
    action_tx: Sender<c_bindings::GuiAction>,
}

pub struct Gui {
    cond: Condvar,
    inner: Mutex<GuiInner>,
    state: *mut c_bindings::AppState,
}

#[no_mangle]
pub extern "C" fn gui_init(state: *mut c_bindings::AppState) -> *mut Gui {
    let (action_tx, action_rx) = mpsc::channel();

    let inner = GuiInner {
        ctx: None,
        action_tx,
        action_rx,
    };

    let gui = Gui {
        cond: Condvar::new(),
        inner: Mutex::new(inner),
        state,
    };

    Box::leak(Box::new(gui))
}

#[no_mangle]
pub extern "C" fn gui_free(gui: *mut Gui) {
    unsafe {
        drop(Box::from_raw(gui));
    }
}

#[no_mangle]
pub extern "C" fn gui_run(gui: *mut Gui, renderer: *mut c_void) {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([350.0, 380.0]),
        multisampling: 4,
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };

    let renderer = RendererPtr(renderer);
    eframe::run_native(
        "video editor",
        options,
        Box::new(move |cc| {
            let action_tx = unsafe {
                let mut inner = (*gui).inner.lock().unwrap();
                inner.ctx = Some(cc.egui_ctx.clone());
                (*gui).cond.notify_all();
                inner.action_tx.clone()
            };
            Box::new(EframeImpl::new(cc, renderer, gui, action_tx))
        }),
    )
    .unwrap();
}

#[no_mangle]
pub unsafe extern "C" fn gui_next_action(gui: *mut Gui) -> c_bindings::GuiAction {
    let inner = (*gui).inner.lock().unwrap();
    if let Ok(v) = inner.action_rx.try_recv() {
        return v;
    }

    c_bindings::GuiAction_gui_action_none
}

#[no_mangle]
pub unsafe extern "C" fn gui_wait_start(gui: *mut Gui) {
    let mut inner = (*gui).inner.lock().unwrap();
    while inner.ctx.is_none() {
        inner = (*gui).cond.wait(inner).unwrap();
    }
}

#[no_mangle]
pub unsafe extern "C" fn gui_notify_update(gui: *mut Gui) {
    let gui = (*gui).inner.lock().unwrap();
    if let Some(ctx) = &gui.ctx {
        ctx.request_repaint();
    }
}

#[no_mangle]
pub unsafe extern "C" fn gui_close(gui: *mut Gui) {
    let gui = (*gui).inner.lock().unwrap();
    if let Some(ctx) = &gui.ctx {
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }
}

struct EframeImpl {
    renderer: RendererPtr,
    action_tx: Sender<c_bindings::GuiAction>,
    gui: *mut Gui,
}

impl EframeImpl {
    fn new(
        cc: &eframe::CreationContext<'_>,
        renderer: RendererPtr,
        gui: *mut Gui,
        action_tx: Sender<c_bindings::GuiAction>,
    ) -> Self {
        let gl = cc
            .gl
            .as_ref()
            .expect("You need to run eframe with the glow backend");

        unsafe {
            let userdata: *const glow::Context = &**gl;
            c_bindings::framerenderer_init_gl(renderer.0, userdata as *mut c_void);
        }
        Self {
            renderer,
            action_tx,
            gui,
        }
    }
}

impl eframe::App for EframeImpl {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut frame = egui::Frame::central_panel(&ctx.style());
        frame.inner_margin = egui::Margin::same(0.0);
        egui::TopBottomPanel::bottom("controls").show(ctx, |ui| {
            let mut state = unsafe { c_bindings::appstate_snapshot((*self.gui).state) };

            let button_text = if state.paused { "play" } else { "pause" };

            ui.horizontal(|ui| {
                if ui.button(button_text).clicked() {
                    self.action_tx
                        .send(c_bindings::GuiAction_gui_action_toggle_pause)
                        .expect("failed to send action from gui");
                };

                ui.with_layout(egui::Layout::right_to_left(Default::default()), |ui| {
                    ui.label(format!(
                        "{:.02}/{:.02}",
                        state.current_position, state.total_runtime
                    ));
                    ui.spacing_mut().slider_width = ui.available_width();
                    ui.add(
                        egui::Slider::new(&mut state.current_position, 0.0..=state.total_runtime)
                            .show_value(false),
                    );
                });
            });
        });
        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
            let rect = ui.max_rect();

            ui.input(|input| {
                for event in &input.events {
                    match event {
                        egui::Event::Key {
                            key: egui::Key::Space,
                            pressed: true,
                            ..
                        } => {
                            self.action_tx
                                .send(c_bindings::GuiAction_gui_action_toggle_pause)
                                .expect("failed to send action from gui");
                        }
                        _ => (),
                    }
                }
            });

            let renderer = self.renderer.clone();

            let callback = egui::PaintCallback {
                rect,
                callback: std::sync::Arc::new(egui_glow::CallbackFn::new(move |_info, painter| {
                    let renderer = &renderer;
                    unsafe {
                        let userdata: *const glow::Context = &**painter.gl();
                        c_bindings::framerenderer_render(
                            renderer.0,
                            rect.width(),
                            rect.height(),
                            userdata as *mut c_void,
                        );
                    }
                })),
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
