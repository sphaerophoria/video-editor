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
pub unsafe extern "C" fn gui_run(
    gui: *mut Gui,
    frame_renderer: *mut c_bindings::FrameRenderer,
    audio_renderer: *mut c_bindings::AudioRenderer,
) {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([800.0, 600.0]),
        multisampling: 4,
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };

    let frame_renderer = RendererPtr(frame_renderer);
    let audio_renderer = RendererPtr(audio_renderer);
    eframe::run_native(
        "video editor",
        options,
        Box::new(move |cc| {
            let mut inner = (*gui).inner.lock().unwrap();
            inner.ctx = Some(cc.egui_ctx.clone());
            (*gui).cond.notify_all();
            let action_tx = inner.action_tx.clone();
            Box::new(EframeImpl::new(
                cc,
                frame_renderer,
                audio_renderer,
                gui,
                action_tx,
            ))
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

/// Conversions between "rect" space, which is the position in the window in pixels, and "audio"
/// space, which is the normalized position in the un-zoomed audio widget.
struct AudioWidgetPosConverter<'a> {
    zoom: &'a f32,
    widget_center_norm: &'a f32,
    rect: &'a egui::Rect,
}

impl AudioWidgetPosConverter<'_> {
    fn audio_to_rect(&self, audio_pos_norm: f32) -> f32 {
        let progress_norm_adjusted = (audio_pos_norm - self.widget_center_norm) * self.zoom + 0.5;
        progress_norm_adjusted * self.rect.width() + self.rect.left()
    }

    fn rect_to_audio(&self, x_pos_rect: f32) -> f32 {
        let rect_pos_norm = (x_pos_rect - self.rect.left()) / self.rect.width();
        (rect_pos_norm - 0.5) / self.zoom + self.widget_center_norm
    }
}

struct ProgressBar {
    paused_on_click: bool,
    zoom: f32,
    widget_center_norm: f32,
}

impl ProgressBar {
    fn handle_seek(
        &mut self,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
    ) {
        let primary_down = response.dragged_by(egui::PointerButton::Primary);
        if primary_down {
            let pos = response
                .interact_pointer_pos()
                .expect("Pointer should interact if dragging");
            let converter = AudioWidgetPosConverter {
                zoom: &self.zoom,
                widget_center_norm: &self.widget_center_norm,
                rect: &response.rect,
            };

            let audio_pos_norm = converter.rect_to_audio(pos.x);
            action_tx
                .send(gui_actions::seek(audio_pos_norm * state.total_runtime))
                .unwrap();
        }

        if response.drag_started_by(egui::PointerButton::Primary) {
            self.paused_on_click = state.paused;
            if !state.paused {
                action_tx.send(gui_actions::TOGGLE_PAUSE).unwrap();
            }
        }

        if response.drag_stopped_by(egui::PointerButton::Primary)
            // You may think we should check the current state here, but that is untrue. When we
            // execute a seek, we may not finish the seek before the next render frame in the UI.
            // Because of this we may not see the applied pause yet. If we manage to check this
            // condition before the pause is applied, we will not correctly unpause orselves.
            //
            // The failure condition here is if we somehow change the pause state while we are
            // seeking (i.e. pressing spacebar), in this case we may end up with an extra toggle
            // that we didn't want, but that's a fine tradeoff here
            && !self.paused_on_click
        {
            action_tx.send(gui_actions::TOGGLE_PAUSE).unwrap();
        }
    }

    fn handle_pan(&mut self, ui: &egui::Ui, response: &egui::Response) {
        if response.dragged_by(egui::PointerButton::Secondary) {
            let x_delta = ui.input(|i| i.pointer.delta().x);
            self.widget_center_norm -= x_delta / response.rect.width() / self.zoom;
            self.widget_center_norm = self.widget_center_norm.clamp(0.0, 1.0);
        }
    }

    fn handle_zoom(&mut self, ui: &egui::Ui, response: &egui::Response) {
        if response.contains_pointer() {
            // If for whatever reason we cannot find the pointer pos, just use the middle of the
            // widget
            let mut pointer_pos_audio = 0.5;
            if let Some(pointer_pos) = ui.input(|i| i.pointer.latest_pos()) {
                // NOTE: We want to zoom so that the mouse stays in the same spot. This means that the
                // distance from the center to the pointer needs to stay the same
                let converter = AudioWidgetPosConverter {
                    zoom: &self.zoom,
                    widget_center_norm: &self.widget_center_norm,
                    rect: &response.rect,
                };
                pointer_pos_audio = converter.rect_to_audio(pointer_pos.x);
            }

            let old_zoom = self.zoom;
            let scroll_delta = ui.input(|i| i.raw_scroll_delta.y);

            // lol I don't know, it feels good to me
            const SCROLL_FACTOR: f32 = 3.0;
            self.zoom *= 1.001_f32.powf(scroll_delta * SCROLL_FACTOR);
            self.zoom = self.zoom.max(1.0);

            // In order to zoom "at the mouse", we have to ensure that mouse position does not
            // change in either audio space OR rect space.
            // We can calculate how far the point moved from the center in audio space, and then
            // just adjust to keep that at the same point in rect space
            let dist_from_center = pointer_pos_audio - self.widget_center_norm;
            let new_dist_from_center = old_zoom / self.zoom * dist_from_center;
            self.widget_center_norm += dist_from_center - new_dist_from_center;
        }
    }

    fn clamp_widget_center(&mut self) {
        let min = 0.5 / self.zoom;
        let max = 1.0 - min;
        self.widget_center_norm = self.widget_center_norm.clamp(min, max);
    }

    fn handle_response(
        &mut self,
        ui: &egui::Ui,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
    ) {
        self.handle_seek(response, state, action_tx);
        self.handle_pan(ui, response);
        self.handle_zoom(ui, response);
        self.clamp_widget_center();
    }

    fn show(
        &mut self,
        ui: &mut egui::Ui,
        state: c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
        audio_renderer: RendererPtr,
    ) {
        let response = ui
            .with_layout(egui::Layout::right_to_left(Default::default()), |ui| {
                let response = ui.allocate_response(
                    egui::vec2(ui.available_width(), 60.0),
                    egui::Sense {
                        click: false,
                        drag: true,
                        focusable: false,
                    },
                );

                let rect = response.rect;
                let zoom = self.zoom;
                let center_norm = self.widget_center_norm;
                let callback = egui::PaintCallback {
                    rect,
                    callback: std::sync::Arc::new(egui_glow::CallbackFn::new(
                        move |_info, painter| {
                            let audio_renderer = &audio_renderer;
                            unsafe {
                                let userdata: *const glow::Context = &**painter.gl();
                                c_bindings::audiorenderer_render(
                                    audio_renderer.0,
                                    userdata as *mut c_void,
                                    zoom,
                                    center_norm,
                                );
                            }
                        },
                    )),
                };
                ui.painter().add(callback);

                let converter = AudioWidgetPosConverter {
                    zoom: &self.zoom,
                    widget_center_norm: &self.widget_center_norm,
                    rect: &rect,
                };

                let progress_rect_cx =
                    converter.audio_to_rect(state.current_position / state.total_runtime);
                let mut progress_rect = rect;
                progress_rect.set_width(2.0);
                progress_rect.set_center(egui::pos2(progress_rect_cx, progress_rect.center().y));

                ui.painter()
                    .rect_filled(progress_rect, 0.0, egui::Color32::YELLOW);

                response
            })
            .inner;

        self.handle_response(ui, &response, &state, action_tx);
    }
}
struct EframeImpl {
    frame_renderer: RendererPtr,
    audio_renderer: RendererPtr,
    action_tx: Sender<c_bindings::GuiAction>,
    gui: *mut Gui,
    progress_bar: ProgressBar,
}

impl EframeImpl {
    fn new(
        cc: &eframe::CreationContext<'_>,
        frame_renderer: RendererPtr,
        audio_renderer: RendererPtr,
        gui: *mut Gui,
        action_tx: Sender<c_bindings::GuiAction>,
    ) -> Self {
        let gl = cc
            .gl
            .as_ref()
            .expect("You need to run eframe with the glow backend");

        unsafe {
            let userdata: *const glow::Context = &**gl;
            c_bindings::framerenderer_init_gl(frame_renderer.0, userdata as *mut c_void);
            c_bindings::audiorenderer_init_gl(audio_renderer.0, userdata as *mut c_void);
        }
        Self {
            frame_renderer,
            audio_renderer,
            action_tx,
            gui,
            progress_bar: ProgressBar {
                paused_on_click: false,
                zoom: 1.0,
                widget_center_norm: 0.5,
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

                ui.label(format!(
                    "{:.02}/{:.02}",
                    state.current_position, state.total_runtime
                ));
                ui.spacing_mut().slider_width = ui.available_width();
            });

            self.progress_bar
                .show(ui, state, &self.action_tx, self.audio_renderer.clone());
        });
        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
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

            let frame_renderer = self.frame_renderer.clone();

            let rect = ui.max_rect();
            let callback = egui::PaintCallback {
                rect,
                callback: std::sync::Arc::new(egui_glow::CallbackFn::new(move |_info, painter| {
                    let frame_renderer = &frame_renderer;
                    unsafe {
                        let userdata: *const glow::Context = &**painter.gl();
                        c_bindings::framerenderer_render(
                            frame_renderer.0,
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
            c_bindings::framerenderer_deinit_gl(self.frame_renderer.0, userdata as *mut c_void);
            c_bindings::audiorenderer_deinit_gl(self.audio_renderer.0, userdata as *mut c_void);
            (*self.gui).inner.lock().unwrap().ctx = None;
        }
    }
}
