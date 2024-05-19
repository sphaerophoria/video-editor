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

mod gui_actions {
    use crate::c_bindings::*;
    pub const NONE: GuiAction = GuiAction {
        tag: GuiActionTag_gui_action_none,
        seek_position: 0.0,
    };

    pub const TOGGLE_PAUSE: GuiAction = GuiAction {
        tag: GuiActionTag_gui_action_toggle_pause,
        seek_position: 0.0,
    };

    pub const CLOSE: GuiAction = GuiAction {
        tag: GuiActionTag_gui_action_close,
        seek_position: 0.0,
    };

    pub fn seek(pos: f32) -> GuiAction {
        GuiAction {
            tag: GuiActionTag_gui_action_seek,
            seek_position: pos,
        }
    }
}

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
pub unsafe extern "C" fn gui_init(state: *mut c_bindings::AppState) -> *mut Gui {
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
pub unsafe extern "C" fn gui_free(gui: *mut Gui) {
    drop(Box::from_raw(gui));
}

#[no_mangle]
pub unsafe extern "C" fn gui_run(gui: *mut Gui, renderer: *mut c_void) {
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
            let mut inner = (*gui).inner.lock().unwrap();
            inner.ctx = Some(cc.egui_ctx.clone());
            (*gui).cond.notify_all();
            let action_tx = inner.action_tx.clone();
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

    if inner.ctx.is_some() {
        gui_actions::NONE
    } else {
        gui_actions::CLOSE
    }
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

struct ProgressBar {
    slider_held: bool,
    paused_on_click: bool,
}

impl ProgressBar {
    fn state_transitioned(&self, pointer_down: bool) -> bool {
        self.slider_held != pointer_down
    }

    fn requires_pauses_toggle(&self, currently_paused: bool) -> bool {
        if self.slider_held && !currently_paused {
            return true;
        }

        if !self.slider_held && currently_paused != self.paused_on_click {
            return true;
        }

        false
    }

    fn handle_response(
        &mut self,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
    ) {
        if response.changed() {
            action_tx
                .send(gui_actions::seek(state.current_position))
                .unwrap();
        }

        let pointer_down = response.is_pointer_button_down_on();
        if !self.state_transitioned(pointer_down) {
            return;
        }
        self.slider_held = pointer_down;

        if self.requires_pauses_toggle(state.paused) {
            action_tx.send(gui_actions::TOGGLE_PAUSE).unwrap();
        }

        if pointer_down {
            self.paused_on_click = state.paused;
        }
    }

    fn show(
        &mut self,
        ui: &mut egui::Ui,
        mut state: c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
    ) {
        let response = ui
            .with_layout(egui::Layout::right_to_left(Default::default()), |ui| {
                ui.label(format!(
                    "{:.02}/{:.02}",
                    state.current_position, state.total_runtime
                ));
                ui.spacing_mut().slider_width = ui.available_width();
                ui.add(
                    egui::Slider::new(&mut state.current_position, 0.0..=state.total_runtime)
                        .smart_aim(false)
                        .show_value(false),
                )
            })
            .inner;

        self.handle_response(&response, &state, action_tx);
    }
}
struct EframeImpl {
    renderer: RendererPtr,
    action_tx: Sender<c_bindings::GuiAction>,
    gui: *mut Gui,
    progress_bar: ProgressBar,
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
            progress_bar: ProgressBar {
                slider_held: false,
                paused_on_click: false,
            },
        }
    }
}

impl eframe::App for EframeImpl {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut frame = egui::Frame::central_panel(&ctx.style());
        frame.inner_margin = egui::Margin::same(0.0);
        egui::TopBottomPanel::bottom("controls").show(ctx, |ui| {
            let state = unsafe { c_bindings::appstate_snapshot((*self.gui).state) };

            let button_text = if state.paused { "play" } else { "pause" };

            ui.horizontal(|ui| {
                if ui.button(button_text).clicked() {
                    self.action_tx
                        .send(gui_actions::TOGGLE_PAUSE)
                        .expect("failed to send action from gui");
                };

                self.progress_bar.show(ui, state, &self.action_tx);
            });
        });
        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
            let rect = ui.max_rect();

            ui.input(|input| {
                for event in &input.events {
                    if let egui::Event::Key {
                        key: egui::Key::Space,
                        pressed: true,
                        ..
                    } = event
                    {
                        self.action_tx
                            .send(gui_actions::TOGGLE_PAUSE)
                            .expect("failed to send action from gui");
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
            (*self.gui).inner.lock().unwrap().ctx = None;
        }
    }
}
