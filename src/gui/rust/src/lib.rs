use eframe::{egui, egui_glow, glow};

use std::{
    ffi::c_void,
    sync::{
        mpsc::{self, Receiver, Sender},
        Arc, Condvar, Mutex,
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

    fn make_action(tag: GuiActionTag) -> GuiAction {
        GuiAction { tag };
    }

    pub fn none() -> GuiAction {
        make_action(GuiActionTag_gui_action_none)
    }

    pub fn toggle_pause() -> GuiAction {
        make_action(GuiActionTag_gui_action_toggle_pause)
    }

    pub fn close() -> GuiAction {
        make_action(GuiActionTag_gui_action_close)
    }

    pub fn seek(pos: f32) -> GuiAction {
        let mut ret = make_action(GuiActionTag_gui_action_seek);
        ret.data.seek_position = pos;
        ret
    }

    pub fn clip_add(clip: &Clip) -> GuiAction {
        let mut ret = make_action(GuiActionTag_gui_action_clip_add);
        ret.data.clip = *clip;
        ret
    }

    pub fn clip_remove(current_pos: f32) -> GuiAction {
        let mut ret = make_action(GuiActionTag_gui_action_clip_remove);
        ret.data.seek_position = current_pos;
        ret
    }

    pub fn clip_edit(clip: &Clip) -> GuiAction {
        let mut ret = make_action(GuiActionTag_gui_action_clip_edit);
        ret.data.clip = *clip;
        ret
    }

    pub fn save() -> GuiAction {
        make_action(GuiActionTag_gui_action_save)
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
    wtm: *mut c_bindings::WordTimestampMap,
) {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([800.0, 600.0]),
        multisampling: 4,
        renderer: eframe::Renderer::Glow,
        ..Default::default()
    };

    let frame_renderer = RendererPtr(frame_renderer);
    let audio_renderer = RendererPtr(audio_renderer);
    let wtm = RendererPtr(wtm);

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
                wtm,
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
        gui_actions::none()
    } else {
        gui_actions::close()
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

struct SeekState {
    paused_on_click: bool,
}

impl SeekState {
    fn should_toggle_pause(
        &mut self,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
    ) -> bool {
        if response.drag_started_by(egui::PointerButton::Primary) {
            self.paused_on_click = state.paused;
            if !state.paused {
                return true;
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
            return true;
        }

        false
    }
}

struct ClipTimelineRenderer<'a> {
    converter: &'a ProgressPosConverter,
    ui: &'a mut egui::Ui,
    progress_bar: &'a mut ProgressBar,
    state: &'a c_bindings::AppStateSnapshot,
    action_tx: &'a Sender<c_bindings::GuiAction>,
}

impl ClipTimelineRenderer<'_> {
    fn render_clip(&mut self, clip: &c_bindings::Clip, seek_state: &mut SeekState) {
        let mut edited_clip = *clip;

        let mut changed = false;

        let sense = egui::Sense {
            click: false,
            drag: true,
            focusable: false,
        };

        let start_rect = self.converter.duration_to_full_rect(clip.start, 2.0);
        let start_response = self.ui.allocate_rect(start_rect, sense);
        if let Some(pos) = self.progress_bar.handle_seek(
            self.converter,
            &start_response,
            self.state,
            self.action_tx,
            seek_state,
        ) {
            changed = true;
            edited_clip.start = pos;
        }

        let end_rect = self.converter.duration_to_full_rect(clip.end, 2.0);
        let end_response = self.ui.allocate_rect(end_rect, sense);
        if let Some(pos) = self.progress_bar.handle_seek(
            self.converter,
            &end_response,
            self.state,
            self.action_tx,
            seek_state,
        ) {
            changed = true;
            edited_clip.end = pos;
        }

        let mut clip_rect = self.converter.rect;
        clip_rect.set_left(self.converter.duration_to_rect_pos(clip.start));
        clip_rect.set_right(self.converter.duration_to_rect_pos(clip.end));

        let stroke = egui::Stroke {
            width: 2.0,
            color: egui::Color32::RED,
        };
        self.ui.painter().rect_stroke(clip_rect, 0.0, stroke);
        let red = egui::Color32::RED;
        let red_feint = egui::Color32::from_rgba_unmultiplied(red.r(), red.g(), red.b(), 20);
        self.ui.painter().rect_filled(clip_rect, 0.0, red_feint);

        if changed {
            self.action_tx
                .send(gui_actions::clip_edit(&edited_clip))
                .unwrap();
        }
    }
}

/// Conversions between "rect" space, which is the position in the window in pixels, and "audio"
/// space, which is the normalized position in the un-zoomed audio widget.
struct ProgressPosConverter {
    zoom: f32,
    widget_center_norm: f32,
    rect: egui::Rect,
    total_runtime: f32,
}

impl ProgressPosConverter {
    fn duration_to_rect_pos(&self, duration_pos: f32) -> f32 {
        let duration_pos_norm = duration_pos / self.total_runtime;
        let duration_norm_adjusted =
            (duration_pos_norm - self.widget_center_norm) * self.zoom + 0.5;
        duration_norm_adjusted * self.rect.width() + self.rect.left()
    }

    fn duration_to_full_rect(&self, duration_pos: f32, width: f32) -> egui::Rect {
        let progress_rect_cx = self.duration_to_rect_pos(duration_pos);
        let mut progress_rect = self.rect;
        progress_rect.set_width(width);
        progress_rect.set_center(egui::pos2(progress_rect_cx, progress_rect.center().y));

        progress_rect
    }

    fn rect_to_duration_norm(&self, x_pos_rect: f32) -> f32 {
        let rect_pos_norm = (x_pos_rect - self.rect.left()) / self.rect.width();
        (rect_pos_norm - 0.5) / self.zoom + self.widget_center_norm
    }

    fn rect_to_duration(&self, x_pos_rect: f32) -> f32 {
        self.rect_to_duration_norm(x_pos_rect) * self.total_runtime
    }
}

struct ProgressBar {
    zoom: f32,
    widget_center_norm: f32,
    pending_clip: Option<c_bindings::Clip>,
}

impl ProgressBar {
    fn handle_clip_creation(
        &mut self,
        converter: &ProgressPosConverter,
        ui: &egui::Ui,
        response: &egui::Response,
        action_tx: &Sender<c_bindings::GuiAction>,
    ) {
        let primary_down = response.dragged_by(egui::PointerButton::Primary);
        let ctrl_down = ui.input(|i| i.modifiers.ctrl);

        if let Some(pending_clip) = &mut self.pending_clip {
            if response.drag_stopped_by(egui::PointerButton::Primary) {
                action_tx.send(gui_actions::clip_add(pending_clip)).unwrap();
                self.pending_clip = None;
            } else {
                let pos = response
                    .interact_pointer_pos()
                    .expect("Pointer should interact if dragging");
                let duration_pos = converter.rect_to_duration(pos.x);
                pending_clip.end = duration_pos;
            }
        } else if primary_down && ctrl_down {
            let pos = response
                .interact_pointer_pos()
                .expect("Pointer should interact if dragging");
            let duration_pos = converter.rect_to_duration(pos.x);
            self.pending_clip = Some(c_bindings::Clip {
                id: 0,
                start: duration_pos,
                end: duration_pos,
            });
        }
    }

    fn handle_seek(
        &mut self,
        converter: &ProgressPosConverter,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
        seek_state: &mut SeekState,
    ) -> Option<f32> {
        let mut ret = None;

        if response.dragged_by(egui::PointerButton::Primary) {
            let pos = response
                .interact_pointer_pos()
                .expect("Pointer should interact if dragging");
            let duration_pos = converter.rect_to_duration(pos.x);
            action_tx.send(gui_actions::seek(duration_pos)).unwrap();
            ret = Some(duration_pos);
        }

        if seek_state.should_toggle_pause(response, state) {
            action_tx.send(gui_actions::toggle_pause()).unwrap();
        }

        ret
    }

    fn handle_pan(&mut self, ui: &egui::Ui, response: &egui::Response) {
        if response.dragged_by(egui::PointerButton::Secondary) {
            let x_delta = ui.input(|i| i.pointer.delta().x);
            self.widget_center_norm -= x_delta / response.rect.width() / self.zoom;
            self.widget_center_norm = self.widget_center_norm.clamp(0.0, 1.0);
        }
    }

    fn handle_zoom(
        &mut self,
        converter: &ProgressPosConverter,
        ui: &egui::Ui,
        response: &egui::Response,
    ) {
        if response.contains_pointer() {
            // If for whatever reason we cannot find the pointer pos, just use the middle of the
            // widget
            let mut pointer_pos_audio = 0.5;
            if let Some(pointer_pos) = ui.input(|i| i.pointer.latest_pos()) {
                // NOTE: We want to zoom so that the mouse stays in the same spot. This means that the
                // distance from the center to the pointer needs to stay the same
                pointer_pos_audio = converter.rect_to_duration_norm(pointer_pos.x);
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
        converter: &ProgressPosConverter,
        ui: &egui::Ui,
        response: &egui::Response,
        state: &c_bindings::AppStateSnapshot,
        action_tx: &Sender<c_bindings::GuiAction>,
        seek_state: &mut SeekState,
    ) {
        self.handle_clip_creation(converter, ui, response, action_tx);
        self.handle_seek(converter, response, state, action_tx, seek_state);
        self.handle_pan(ui, response);
        self.handle_zoom(converter, ui, response);
        self.clamp_widget_center();
    }

    fn show(
        &mut self,
        ui: &mut egui::Ui,
        state: &SnapshotHolder,
        action_tx: &Sender<c_bindings::GuiAction>,
        audio_renderer: RendererPtr,
        seek_state: &mut SeekState,
    ) {
        ui.with_layout(egui::Layout::right_to_left(Default::default()), |ui| {
            let response = ui.allocate_response(
                egui::vec2(ui.available_width(), 60.0),
                egui::Sense {
                    click: false,
                    drag: true,
                    focusable: false,
                },
            );

            let converter = ProgressPosConverter {
                zoom: self.zoom,
                widget_center_norm: self.widget_center_norm,
                rect: response.rect,
                total_runtime: state.total_runtime,
            };

            let rect = response.rect;
            let zoom = self.zoom;
            let center_norm = self.widget_center_norm;
            let callback = egui::PaintCallback {
                rect,
                callback: std::sync::Arc::new(egui_glow::CallbackFn::new(move |_info, painter| {
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
                })),
            };
            ui.painter().add(callback);

            let pending_clip = self.pending_clip;
            let mut clip_renderer = ClipTimelineRenderer {
                converter: &converter,
                ui,
                progress_bar: self,
                state,
                action_tx,
            };

            for i in 0..state.num_clips {
                let clip = unsafe { *state.clips.add(i as usize) };
                clip_renderer.render_clip(&clip, seek_state);
            }

            if let Some(pending_clip) = pending_clip {
                clip_renderer.render_clip(&pending_clip, seek_state)
            }

            let progress_rect = converter.duration_to_full_rect(state.current_position, 3.0);
            ui.painter()
                .rect_filled(progress_rect, 0.0, egui::Color32::YELLOW);

            self.handle_response(&converter, ui, &response, state, action_tx, seek_state);
        });
    }
}

struct SnapshotHolder {
    app_state: *mut c_bindings::AppState,
    snapshot: c_bindings::AppStateSnapshot,
}

impl SnapshotHolder {
    fn new(app_state: *mut c_bindings::AppState) -> SnapshotHolder {
        let snapshot = unsafe { c_bindings::appstate_snapshot(app_state) };
        SnapshotHolder {
            app_state,
            snapshot,
        }
    }
}

impl std::ops::Deref for SnapshotHolder {
    type Target = c_bindings::AppStateSnapshot;
    fn deref(&self) -> &Self::Target {
        &self.snapshot
    }
}

impl Drop for SnapshotHolder {
    fn drop(&mut self) {
        unsafe { c_bindings::appstate_deinit(self.app_state, &self.snapshot) }
    }
}

struct EframeImpl {
    frame_renderer: RendererPtr,
    audio_renderer: RendererPtr,
    wtm: RendererPtr,
    action_tx: Sender<c_bindings::GuiAction>,
    gui: *mut Gui,
    progress_bar: ProgressBar,
    seek_state: SeekState,
}

impl EframeImpl {
    fn new(
        cc: &eframe::CreationContext<'_>,
        frame_renderer: RendererPtr,
        audio_renderer: RendererPtr,
        wtm: RendererPtr,
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
            wtm,
            action_tx,
            gui,
            progress_bar: ProgressBar {
                zoom: 1.0,
                widget_center_norm: 0.5,
                pending_clip: None,
            },
            seek_state: SeekState {
                paused_on_click: false,
            },
        }
    }
}

impl eframe::App for EframeImpl {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut frame = egui::Frame::central_panel(&ctx.style());
        frame.inner_margin = egui::Margin::same(0.0);

        let state = unsafe { SnapshotHolder::new((*self.gui).state) };

        egui::TopBottomPanel::bottom("controls").show(ctx, |ui| {
            let button_text = if state.paused { "play" } else { "pause" };

            ui.horizontal(|ui| {
                if ui.button(button_text).clicked() {
                    self.action_tx
                        .send(gui_actions::toggle_pause())
                        .expect("failed to send action from gui");
                };

                ui.label(format!(
                    "{:.02}/{:.02}",
                    state.current_position, state.total_runtime
                ));
                ui.spacing_mut().slider_width = ui.available_width();

                if ui.button("Delete clip").clicked() {
                    self.action_tx
                        .send(gui_actions::clip_remove(state.current_position))
                        .unwrap();
                }
            });

            self.progress_bar.show(
                ui,
                &state,
                &self.action_tx,
                self.audio_renderer.clone(),
                &mut self.seek_state,
            );
        });

        egui::SidePanel::right("script").show(ctx, |ui| unsafe {
            let s = std::slice::from_raw_parts(state.text as *const u8, state.text_len as usize);
            let s = std::str::from_utf8_unchecked(s);

            let mut font_id = ui.style().text_styles[&egui::TextStyle::Body].clone();
            font_id.size = 20.0;
            let wrap_width = ui.available_width();

            let layout = egui::text::LayoutJob::simple(
                s.to_string(),
                font_id,
                ui.visuals().text_color(),
                wrap_width,
            );
            let galley = ui.painter().layout_job(layout);
            egui::ScrollArea::vertical()
                .drag_to_scroll(false)
                .show(ui, |ui| {
                    let response = ui.allocate_response(
                        galley.rect.size(),
                        egui::Sense {
                            click: false,
                            drag: true,
                            focusable: false,
                        },
                    );
                    ui.painter().galley(
                        egui::pos2(response.rect.left(), response.rect.top()),
                        Arc::clone(&galley),
                        egui::Color32::WHITE,
                    );

                    if self.seek_state.should_toggle_pause(&response, &state) {
                        self.action_tx.send(gui_actions::toggle_pause()).unwrap();
                    }

                    if response.dragged_by(egui::PointerButton::Primary) {
                        let mut pixel_pos = response.interact_pointer_pos().unwrap();
                        pixel_pos.y -= response.rect.top();
                        pixel_pos.x -= response.rect.left();
                        let mut row = 0;
                        let mut col = 0;
                        let mut char_pos = 0;

                        while row < galley.rows.len()
                            && galley.rows[row].rect.bottom() < pixel_pos.y
                        {
                            char_pos += galley.rows[row].glyphs.len();
                            row += 1;
                        }
                        // I want B to be no larger then A
                        // The maximum value of B is A
                        // max(a, b)
                        row = row.min(galley.rows.len() - 1);

                        let glyphs = &galley.rows[row].glyphs;
                        while col < glyphs.len()
                            && glyphs[col].pos.x + glyphs[col].size.x < pixel_pos.x
                        {
                            char_pos += 1;
                            col += 1;
                        }

                        let pts = c_bindings::wtm_get_time(self.wtm.0, char_pos as u64);
                        self.action_tx.send(gui_actions::seek(pts)).unwrap();
                    }
                });
        });

        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
            ui.input(|input| {
                for event in &input.events {
                    match event {
                        egui::Event::Key {
                            key: egui::Key::Space,
                            pressed: true,
                            ..
                        } => {
                            self.action_tx
                                .send(gui_actions::toggle_pause())
                                .expect("failed to send action from gui");
                        }
                        egui::Event::Key {
                            key: egui::Key::S,
                            pressed: true,
                            modifiers: egui::Modifiers { ctrl: true, .. },
                            ..
                        } => {
                            self.action_tx
                                .send(gui_actions::save())
                                .expect("failed to send save action from gui");
                        }
                        _ => (),
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
