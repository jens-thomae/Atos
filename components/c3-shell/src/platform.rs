// SPDX-License-Identifier: MIT OR Apache-2.0
//! A Slint platform on smithay-client-toolkit: every top-level Slint window becomes a
//! wlr-layer-shell surface on one output, rendered by Slint's public FemtoVG renderer on EGL
//! (glutin). Each surface gets its own AccessKit adapter (`accesskit_unix`), fed by the port of
//! Slint's tree builder in `accesskit.rs`.
//!
//! Taken from the layer-shell spike (#59, `spikes/c4-layer-shell/src/platform.rs`), minus its
//! popups, popup pool and timing hooks (no shell popover yet), plus one surface per output.
//! Slint internals used (no semver promise, see docs/components/c4-toolkit/layer-shell-spike.md):
//! `WindowAdapter::internal` with `i_slint_core::InternalToken` and `WindowAdapterInternal`
//! (`handle_focus_change`, `register_item_tree`, `unregister_item_tree`).
//!
//! ponytail: the spike's scope. Scale 1, no key repeat, no modifiers, no cursor shapes, no IME,
//! no clipboard. Each is a card in the spike's write-up (section 6); the C4 backend crate
//! (card 1 there) replaces this file.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::num::NonZeroU32;
use std::ptr::NonNull;
use std::rc::{Rc, Weak};

use glutin::api::egl::config::Config;
use glutin::api::egl::context::PossiblyCurrentContext;
use glutin::api::egl::display::Display;
use glutin::api::egl::surface::Surface;
use glutin::config::ConfigTemplateBuilder;
use glutin::context::{ContextApi, ContextAttributesBuilder, PossiblyCurrentGlContext};
use glutin::display::GlDisplay;
use glutin::surface::{GlSurface, SurfaceAttributesBuilder, SwapInterval, WindowSurface};
use i_slint_core::window::WindowAdapterInternal;
use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
};
use sctk::compositor::{CompositorHandler, CompositorState};
use sctk::output::{OutputHandler, OutputState};
use sctk::reexports::calloop::{EventLoop, channel};
use sctk::reexports::calloop_wayland_source::WaylandSource;
use sctk::reexports::client::globals::{GlobalList, registry_queue_init};
use sctk::reexports::client::protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_surface};
use sctk::reexports::client::{Connection, Proxy, QueueHandle};
use sctk::registry::{ProvidesRegistryState, RegistryState};
use sctk::seat::keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers};
use sctk::seat::pointer::{PointerEvent, PointerEventKind, PointerHandler};
use sctk::seat::{Capability, SeatHandler, SeatState};
use sctk::shell::WaylandSurface;
use sctk::shell::wlr_layer::{
    Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
    LayerSurfaceConfigure,
};
use slint::platform::femtovg_renderer::{FemtoVGRenderer, OpenGLInterface};
use slint::platform::{
    Key, Platform, PlatformError, PointerEventButton, Renderer, WindowAdapter, WindowEvent,
    WindowProperties,
};
use slint::{LogicalPosition, LogicalSize, PhysicalSize, WindowSize};

use crate::accesskit::{AccessKitAdapter, DeferredAccessKitAction};
use crate::toplevels;

type Task = Box<dyn FnOnce() + Send>;
type WindowTask = Box<dyn FnOnce(&Rc<LayerWindow>) + Send>;
type OutputHook = Box<dyn FnMut(&wl_output::WlOutput, bool)>;
type ShownHook = Box<dyn Fn(&slint::Window)>;

/// How a layer surface sits on its output: the edges it is anchored to and its margin
/// (top, right, bottom, left) in logical pixels. The exclusive zone is its height.
#[derive(Clone, Copy)]
pub struct Placement {
    pub anchor: Anchor,
    pub margin: [i32; 4],
    /// The launcher (#64): overlay layer above everything, the keyboard while shown, no exclusive
    /// zone and drawn over other surfaces' zones.
    pub overlay: bool,
}

/// Wayland objects every window needs. Shared, read-only after start-up.
struct Globals {
    conn: Connection,
    qh: QueueHandle<State>,
    compositor: CompositorState,
    layer_shell: LayerShell,
    egl: Display,
    egl_config: Config,
    tx: channel::Sender<Task>,
}

thread_local! {
    static GLOBALS: RefCell<Option<Rc<Globals>>> = const { RefCell::new(None) };
    static WINDOWS: RefCell<Vec<Weak<LayerWindow>>> = const { RefCell::new(Vec::new()) };
    static SEAT: RefCell<Option<wl_seat::WlSeat>> = const { RefCell::new(None) };
    static QUIT: Cell<bool> = const { Cell::new(false) };
    static FIRST_FRAME: Cell<bool> = const { Cell::new(true) };
    /// Output for the next window created (`with_output`), placement for the next shown.
    static NEXT_OUTPUT: RefCell<Option<wl_output::WlOutput>> = const { RefCell::new(None) };
    static NEXT_PLACEMENT: Cell<Option<Placement>> = const { Cell::new(None) };
    static OUTPUTS: RefCell<Vec<wl_output::WlOutput>> = const { RefCell::new(Vec::new()) };
    static OUTPUT_HOOK: RefCell<Option<OutputHook>> = const { RefCell::new(None) };
    static SHOWN_HOOKS: RefCell<Vec<ShownHook>> = const { RefCell::new(Vec::new()) };
}

/// Calls `hook` with the window whenever the compositor reports a frame of it as shown (wl_surface
/// frame callback). Any number of hooks; the control centre times its opening with one.
pub fn on_shown(hook: impl Fn(&slint::Window) + 'static) {
    SHOWN_HOOKS.with(|h| h.borrow_mut().push(Box::new(hook)));
}

fn globals() -> Rc<Globals> {
    GLOBALS.with(|g| g.borrow().clone().expect("platform not initialised"))
}

fn windows() -> Vec<Rc<LayerWindow>> {
    WINDOWS.with(|w| {
        let mut w = w.borrow_mut();
        w.retain(|w| w.strong_count() > 0);
        w.iter().filter_map(Weak::upgrade).collect()
    })
}

fn window_for_surface(s: &wl_surface::WlSurface) -> Option<Rc<LayerWindow>> {
    windows().into_iter().find(|w| &w.surface == s)
}

fn window_by_id(id: u32) -> Option<Rc<LayerWindow>> {
    windows().into_iter().find(|w| w.id == id)
}

/// The seat the shell acts for (activation needs one).
pub fn seat() -> Option<wl_seat::WlSeat> {
    SEAT.with(|s| s.borrow().clone())
}

/// Windows created inside `f` become layer surfaces on `output`. Windows created outside it go on
/// the output the compositor picks (the focused one).
pub fn with_output<R>(output: &wl_output::WlOutput, f: impl FnOnce() -> R) -> R {
    NEXT_OUTPUT.with(|n| *n.borrow_mut() = Some(output.clone()));
    let r = f();
    NEXT_OUTPUT.with(|n| n.borrow_mut().take());
    r
}

/// Windows shown inside `f` take this placement on their output.
pub fn with_placement<R>(placement: Placement, f: impl FnOnce() -> R) -> R {
    NEXT_PLACEMENT.with(|n| n.set(Some(placement)));
    let r = f();
    NEXT_PLACEMENT.with(|n| n.set(None));
    r
}

/// Calls `hook(output, true)` for every output now and every one added later, and
/// `hook(output, false)` when one goes away.
pub fn on_outputs(mut hook: impl FnMut(&wl_output::WlOutput, bool) + 'static) {
    for o in OUTPUTS.with(|o| o.borrow().clone()) {
        hook(&o, true);
    }
    OUTPUT_HOOK.with(|h| *h.borrow_mut() = Some(Box::new(hook)));
}

fn output_changed(output: &wl_output::WlOutput, added: bool) {
    OUTPUTS.with(|o| {
        let mut o = o.borrow_mut();
        o.retain(|x| x != output);
        if added {
            o.push(output.clone());
        }
    });
    // Taken out while it runs: the hook creates windows, which must not find it borrowed.
    let hook = OUTPUT_HOOK.with(|h| h.borrow_mut().take());
    if let Some(mut hook) = hook {
        hook(output, added);
        OUTPUT_HOOK.with(|h| *h.borrow_mut() = Some(hook));
    }
}

// --- platform ---------------------------------------------------------------------------------

pub struct WaylandPlatform {
    queue: RefCell<Option<(sctk::reexports::client::EventQueue<State>, State)>>,
    rx: RefCell<Option<channel::Channel<Task>>>,
}

impl WaylandPlatform {
    pub fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let conn = Connection::connect_to_env()?;
        let (global_list, mut queue) = registry_queue_init::<State>(&conn)?;
        let qh = queue.handle();
        let compositor = CompositorState::bind(&global_list, &qh)?;
        let layer_shell = LayerShell::bind(&global_list, &qh)?;
        toplevels::bind(&global_list, &qh);

        // SAFETY: the display pointer comes from the live connection, which `Globals` keeps open
        // for as long as the EGL display exists.
        let egl = unsafe {
            let ptr =
                NonNull::new(conn.backend().display_ptr() as *mut c_void).ok_or("no wl_display")?;
            Display::new(RawDisplayHandle::Wayland(WaylandDisplayHandle::new(ptr)))?
        };
        // SAFETY: no window handle is needed to pick a config.
        let egl_config =
            unsafe { egl.find_configs(ConfigTemplateBuilder::new().with_alpha_size(8).build())? }
                .next()
                .ok_or("no EGL config")?;

        let (tx, rx) = channel::channel::<Task>();
        let mut state = State::new(&global_list, &qh);
        GLOBALS.with(|g| {
            *g.borrow_mut() = Some(Rc::new(Globals {
                conn,
                qh,
                compositor,
                layer_shell,
                egl,
                egl_config,
                tx,
            }))
        });
        // Two round trips: globals, then the outputs' and toplevels' initial events.
        queue.roundtrip(&mut state)?;
        queue.roundtrip(&mut state)?;
        Ok(Self {
            queue: RefCell::new(Some((queue, state))),
            rx: RefCell::new(Some(rx)),
        })
    }
}

struct Proxy_(channel::Sender<Task>);

impl slint::platform::EventLoopProxy for Proxy_ {
    fn quit_event_loop(&self) -> Result<(), slint::EventLoopError> {
        self.0
            .send(Box::new(|| QUIT.with(|q| q.set(true))))
            .map_err(|_| slint::EventLoopError::EventLoopTerminated)
    }
    fn invoke_from_event_loop(
        &self,
        f: Box<dyn FnOnce() + Send>,
    ) -> Result<(), slint::EventLoopError> {
        self.0
            .send(f)
            .map_err(|_| slint::EventLoopError::EventLoopTerminated)
    }
}

impl Platform for WaylandPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        Ok(LayerWindow::new()?)
    }

    fn new_event_loop_proxy(&self) -> Option<Box<dyn slint::platform::EventLoopProxy>> {
        Some(Box::new(Proxy_(globals().tx.clone())))
    }

    fn run_event_loop(&self) -> Result<(), PlatformError> {
        let (queue, mut state) = self
            .queue
            .borrow_mut()
            .take()
            .ok_or("event loop already ran")?;
        let rx = self
            .rx
            .borrow_mut()
            .take()
            .ok_or("event loop already ran")?;
        let mut event_loop: EventLoop<State> = EventLoop::try_new().map_err(|e| e.to_string())?;
        let conn = globals().conn.clone();
        WaylandSource::new(conn, queue)
            .insert(event_loop.handle())
            .map_err(|e| e.to_string())?;
        event_loop
            .handle()
            .insert_source(rx, |ev, _, _| {
                if let channel::Event::Msg(f) = ev {
                    f()
                }
            })
            .map_err(|e| e.to_string())?;
        QUIT.with(|q| q.set(false));
        while !QUIT.with(Cell::get) {
            slint::platform::update_timers_and_animations();
            for w in windows() {
                w.render_if_needed();
            }
            globals().conn.flush().ok();
            let timeout = slint::platform::duration_until_next_timer_update();
            event_loop
                .dispatch(timeout, &mut state)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

// --- EGL ----------------------------------------------------------------------------------------

/// The context starts surfaceless; the EGL window surface is created on configure at the
/// configured size and dropped on hide. Mesa applies a wl_egl_window resize only after the next
/// swap, so a surface created early at a placeholder size shows its first frame at that size.
struct Gl {
    ctx: PossiblyCurrentContext,
    surface: RefCell<Option<Surface<WindowSurface>>>,
}

impl Gl {
    fn attach(
        &self,
        wl: &wl_surface::WlSurface,
        w: u32,
        h: u32,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let g = globals();
        if let Some(s) = &*self.surface.borrow() {
            s.resize(
                &self.ctx,
                NonZeroU32::new(w).ok_or("0 width")?,
                NonZeroU32::new(h).ok_or("0 height")?,
            );
            return Ok(());
        }
        let handle = RawWindowHandle::Wayland(WaylandWindowHandle::new(
            NonNull::new(wl.id().as_ptr() as *mut c_void).ok_or("no wl_surface")?,
        ));
        let attrs = SurfaceAttributesBuilder::<WindowSurface>::new().build(
            handle,
            NonZeroU32::new(w).ok_or("0 width")?,
            NonZeroU32::new(h).ok_or("0 height")?,
        );
        // SAFETY: the wl_surface outlives the EGL surface: `detach` runs on hide and in Drop,
        // before the wl_surface is destroyed.
        let surface = unsafe { g.egl.create_window_surface(&g.egl_config, &attrs)? };
        self.ctx.make_current(&surface)?;
        // Frame callbacks pace us; a blocking eglSwapBuffers would stall the other surfaces.
        surface
            .set_swap_interval(&self.ctx, SwapInterval::DontWait)
            .ok();
        *self.surface.borrow_mut() = Some(surface);
        Ok(())
    }

    fn detach(&self) {
        if self.surface.borrow_mut().take().is_some() {
            self.ctx.make_current_surfaceless().ok();
        }
    }
}

struct GlRef(Rc<Gl>);

// SAFETY: forwards to EGL through glutin; the context lives as long as the renderer.
unsafe impl OpenGLInterface for GlRef {
    fn ensure_current(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let gl = &self.0;
        match &*gl.surface.borrow() {
            Some(s) if !gl.ctx.is_current() => gl.ctx.make_current(s)?,
            None if !gl.ctx.is_current() => gl.ctx.make_current_surfaceless()?,
            _ => {}
        }
        Ok(())
    }
    fn swap_buffers(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        match &*self.0.surface.borrow() {
            Some(s) => Ok(s.swap_buffers(&self.0.ctx)?),
            None => Ok(()),
        }
    }
    fn resize(
        &self,
        w: NonZeroU32,
        h: NonZeroU32,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if let Some(s) = &*self.0.surface.borrow() {
            self.ensure_current()?;
            s.resize(&self.0.ctx, w, h);
        }
        Ok(())
    }
    fn get_proc_address(&self, name: &std::ffi::CStr) -> *const c_void {
        globals().egl.get_proc_address(name)
    }
}

/// The GL renderer this process actually got, on stderr: proof that a measurement ran on the GPU.
fn log_gl_renderer(egl: &Display) {
    const GL_RENDERER: u32 = 0x1F01;
    let f = egl.get_proc_address(c"glGetString");
    if f.is_null() {
        return;
    }
    // SAFETY: glGetString has this signature; a context is current; the result is a static string.
    let name = unsafe {
        let gl_get_string: extern "C" fn(u32) -> *const std::ffi::c_char = std::mem::transmute(f);
        let p = gl_get_string(GL_RENDERER);
        if p.is_null() {
            return;
        } else {
            std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    };
    eprintln!("ATOS_SHELL_GL_RENDERER: {name}");
}

// --- window -------------------------------------------------------------------------------------

pub struct LayerWindow {
    id: u32,
    window: slint::Window,
    output: Option<wl_output::WlOutput>,
    surface: wl_surface::WlSurface,
    /// `Some` while shown. sctk destroys the wl_surface when this is dropped, so a hidden
    /// window cannot be shown again (the shell drops it instead).
    layer: RefCell<Option<LayerSurface>>,
    renderer: FemtoVGRenderer,
    gl: Rc<Gl>,
    size: Cell<PhysicalSize>,
    preferred: Cell<LogicalSize>,
    configured: Cell<bool>,
    dirty: Cell<bool>,
    frame_pending: Cell<bool>,
    focused: Cell<bool>,
    accesskit: RefCell<AccessKitAdapter>,
}

impl LayerWindow {
    fn new() -> Result<Rc<Self>, PlatformError> {
        static NEXT_ID: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
        let id = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let g = globals();
        let surface = g.compositor.create_surface(&g.qh);
        // The context exists from the start (surfaceless), so the public `FemtoVGRenderer::new`
        // can be used and `renderer()` always has a renderer to return (Slint measures text
        // through it before a window is shown).
        let gl = (|| -> Result<Gl, Box<dyn std::error::Error>> {
            let cattrs = ContextAttributesBuilder::new()
                .with_context_api(ContextApi::Gles(None))
                .build(None);
            // SAFETY: no window handle is involved; the display outlives the context (Globals).
            let ctx = unsafe { g.egl.create_context(&g.egl_config, &cattrs)? }
                .make_current_surfaceless()?;
            if id == 1 {
                log_gl_renderer(&g.egl);
            }
            Ok(Gl {
                ctx,
                surface: RefCell::new(None),
            })
        })()
        .map_err(|e| PlatformError::Other(format!("EGL: {e}")))?;
        let gl = Rc::new(gl);
        let renderer = FemtoVGRenderer::new(GlRef(gl.clone()))?;

        let w = Rc::new_cyclic(|self_weak: &Weak<Self>| Self {
            id,
            window: slint::Window::new(self_weak.clone() as Weak<dyn WindowAdapter>),
            output: NEXT_OUTPUT.with(|n| n.borrow().clone()),
            surface,
            layer: RefCell::new(None),
            renderer,
            gl,
            size: Cell::new(PhysicalSize::new(1, 1)),
            preferred: Cell::new(LogicalSize::new(0., 0.)),
            configured: Cell::new(false),
            dirty: Cell::new(true),
            frame_pending: Cell::new(false),
            focused: Cell::new(false),
            accesskit: RefCell::new(AccessKitAdapter::new(self_weak.clone())),
        });
        WINDOWS.with(|ws| ws.borrow_mut().push(Rc::downgrade(&w)));
        Ok(w)
    }

    /// Registers this surface as a window of our application on the AT-SPI bus. accesskit_unix
    /// calls the handlers on its own thread; they forward to the event loop.
    fn platform_accesskit_adapter(&self) -> accesskit_unix::Adapter {
        let (tx, id) = (globals().tx.clone(), self.id);
        let send = move |f: WindowTask| {
            let _ = tx.send(Box::new(move || {
                if let Some(w) = window_by_id(id) {
                    f(&w)
                }
            }));
        };
        accesskit_unix::Adapter::new(
            AkHandler(send.clone()),
            AkHandler(send.clone()),
            AkHandler(send),
        )
    }

    pub fn has_keyboard_focus(&self) -> bool {
        self.focused.get()
    }

    pub fn with_access_kit_adapter_from_weak_window_adapter(
        weak: Weak<Self>,
        callback: impl FnOnce(&RefCell<AccessKitAdapter>),
    ) {
        if let Some(w) = weak.upgrade() {
            callback(&w.accesskit)
        }
    }

    fn show(&self) -> Result<(), PlatformError> {
        let g = globals();
        let mut layer = self.layer.borrow_mut();
        if layer.is_some() {
            return Ok(());
        }
        let placement = NEXT_PLACEMENT
            .with(Cell::get)
            .ok_or("a shell window needs a placement (platform::with_placement)")?;
        self.accesskit
            .borrow_mut()
            .set_platform_adapter(Some(self.platform_accesskit_adapter()));
        let surface = g.layer_shell.create_layer_surface(
            &g.qh,
            self.surface.clone(),
            if placement.overlay {
                Layer::Overlay
            } else {
                Layer::Top
            },
            Some("atos-shell"),
            self.output.as_ref(),
        );
        let preferred = self.preferred.get();
        let height = if placement.anchor.contains(Anchor::TOP | Anchor::BOTTOM) {
            0
        } else {
            preferred.height.max(1.) as u32
        };
        let width = if placement.anchor.contains(Anchor::LEFT | Anchor::RIGHT) {
            0 // stretched between the margins
        } else {
            preferred.width.max(1.) as u32
        };
        let [top, right, bottom, left] = placement.margin;
        surface.set_anchor(placement.anchor);
        surface.set_margin(top, right, bottom, left);
        surface.set_size(width, height);
        if placement.overlay {
            surface.set_exclusive_zone(-1);
            surface.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        } else {
            surface.set_exclusive_zone(height as i32);
            surface.set_keyboard_interactivity(KeyboardInteractivity::OnDemand);
        }
        surface.commit();
        *layer = Some(surface);
        Ok(())
    }

    fn hide(&self) {
        // The EGL surface goes first: it must not outlive the wl_surface, which dropping the
        // LayerSurface destroys.
        self.gl.detach();
        self.layer.borrow_mut().take();
        self.accesskit.borrow_mut().set_platform_adapter(None);
        self.configured.set(false);
        self.frame_pending.set(false);
    }

    fn configure(&self, width: u32, height: u32) {
        let size = PhysicalSize::new(width.max(1), height.max(1));
        self.size.set(size);
        if let Err(e) = self.gl.attach(&self.surface, size.width, size.height) {
            eprintln!("EGL surface: {e}");
            return;
        }
        self.window
            .dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: 1.0 });
        self.window.dispatch_event(WindowEvent::Resized {
            size: size.to_logical(1.0),
        });
        self.accesskit
            .borrow_mut()
            .set_root_window_bounds(accesskit::Rect::new(
                0.,
                0.,
                size.width as f64,
                size.height as f64,
            ));
        self.configured.set(true);
        self.dirty.set(true);
    }

    fn render_if_needed(&self) {
        if !self.dirty.get() || !self.configured.get() || self.frame_pending.get() {
            return;
        }
        self.dirty.set(false);
        let g = globals();
        self.surface.frame(&g.qh, self.surface.clone());
        self.frame_pending.set(true);
        if let Err(e) = self.renderer.render() {
            eprintln!("render: {e}");
        }
        // The budgets harness (docs/budgets.md) times start-up to this line.
        if FIRST_FRAME.replace(false) {
            use std::io::Write;
            println!("BUDGET_FIRST_FRAME");
            std::io::stdout().flush().ok();
        }
    }

    fn invoke_deferred(&self, action: Option<DeferredAccessKitAction>) {
        if let Some(a) = action {
            a.invoke(&self.window);
        }
    }

    fn dispatch(&self, e: WindowEvent) {
        self.window.dispatch_event(e);
    }
}

impl Drop for LayerWindow {
    fn drop(&mut self) {
        self.gl.detach();
        // Dropping the LayerSurface destroys the wl_surface; otherwise destroy it here.
        if self.layer.get_mut().take().is_none() {
            self.surface.destroy();
        }
    }
}

impl WindowAdapter for LayerWindow {
    fn window(&self) -> &slint::Window {
        &self.window
    }

    fn set_visible(&self, visible: bool) -> Result<(), PlatformError> {
        if visible {
            self.show()
        } else {
            self.hide();
            Ok(())
        }
    }

    fn set_size(&self, size: WindowSize) {
        self.size.set(size.to_physical(1.0));
    }

    fn size(&self) -> PhysicalSize {
        self.size.get()
    }

    fn request_redraw(&self) {
        self.dirty.set(true);
    }

    fn renderer(&self) -> &dyn Renderer {
        &self.renderer
    }

    fn update_window_properties(&self, properties: WindowProperties<'_>) {
        self.preferred
            .set(properties.layout_constraints().preferred);
    }

    fn internal(&self, _: i_slint_core::InternalToken) -> Option<&dyn WindowAdapterInternal> {
        Some(self)
    }
}

impl WindowAdapterInternal for LayerWindow {
    fn handle_focus_change(
        &self,
        _old: Option<i_slint_core::items::ItemRc>,
        _new: Option<i_slint_core::items::ItemRc>,
    ) {
        if let Ok(mut a) = self.accesskit.try_borrow_mut() {
            a.handle_focus_item_change();
        }
    }

    fn register_item_tree(&self, _: i_slint_core::item_tree::ItemTreeRefPin) {
        if let Ok(mut a) = self.accesskit.try_borrow_mut() {
            a.reload_tree();
        }
    }

    fn unregister_item_tree(
        &self,
        component: i_slint_core::item_tree::ItemTreeRef,
        _: &mut dyn Iterator<Item = std::pin::Pin<i_slint_core::items::ItemRef<'_>>>,
    ) {
        if let Ok(mut a) = self.accesskit.try_borrow_mut() {
            a.unregister_item_tree(component);
        }
    }
}

// --- AccessKit handlers (called on accesskit_unix's thread; forwarded to the event loop) ---------

#[derive(Clone)]
struct AkHandler<F>(F);

impl<F: Fn(WindowTask)> accesskit::ActivationHandler for AkHandler<F> {
    fn request_initial_tree(&mut self) -> Option<accesskit::TreeUpdate> {
        (self.0)(Box::new(|w| {
            let a = w
                .accesskit
                .borrow_mut()
                .process_accesskit_event(crate::accesskit::AkEvent::InitialTreeRequested);
            w.invoke_deferred(a);
        }));
        None
    }
}

impl<F: Fn(WindowTask)> accesskit::ActionHandler for AkHandler<F> {
    fn do_action(&mut self, request: accesskit::ActionRequest) {
        (self.0)(Box::new(move |w| {
            let a = w
                .accesskit
                .borrow_mut()
                .process_accesskit_event(crate::accesskit::AkEvent::ActionRequested(request));
            w.invoke_deferred(a);
        }));
    }
}

impl<F: Fn(WindowTask)> accesskit::DeactivationHandler for AkHandler<F> {
    fn deactivate_accessibility(&mut self) {
        (self.0)(Box::new(|w| {
            w.accesskit
                .borrow_mut()
                .process_accesskit_event(crate::accesskit::AkEvent::AccessibilityDeactivated);
        }));
    }
}

// --- Wayland dispatch -------------------------------------------------------------------------

pub struct State {
    registry: RegistryState,
    seat: SeatState,
    output: OutputState,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    keyboard_focus: Option<wl_surface::WlSurface>,
}

impl State {
    fn new(globals: &GlobalList, qh: &QueueHandle<Self>) -> Self {
        Self {
            registry: RegistryState::new(globals),
            seat: SeatState::new(globals, qh),
            output: OutputState::new(globals, qh),
            keyboard: None,
            pointer: None,
            keyboard_focus: None,
        }
    }
}

impl CompositorHandler for State {
    fn scale_factor_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: i32,
    ) {
    }
    fn transform_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: wl_output::Transform,
    ) {
    }
    fn frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        _: u32,
    ) {
        if let Some(w) = window_for_surface(surface) {
            w.frame_pending.set(false);
            if w.window.has_active_animations() {
                w.dirty.set(true);
            }
            SHOWN_HOOKS.with(|h| h.borrow().iter().for_each(|f| f(&w.window)));
        }
    }
    fn surface_enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
    fn surface_leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for State {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, o: wl_output::WlOutput) {
        output_changed(&o, true);
    }
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, o: wl_output::WlOutput) {
        output_changed(&o, false);
    }
}

impl LayerShellHandler for State {
    // The compositor closes a layer surface when its output goes away; `output_destroyed`
    // drops the window.
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) {}
    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        layer: &LayerSurface,
        c: LayerSurfaceConfigure,
        _: u32,
    ) {
        if let Some(w) = window_for_surface(layer.wl_surface()) {
            w.configure(c.new_size.0, c.new_size.1);
        }
    }
}

impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(
        &mut self,
        _: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        cap: Capability,
    ) {
        SEAT.with(|s| *s.borrow_mut() = Some(seat.clone()));
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seat.get_keyboard(qh, &seat, None).ok();
        }
        if cap == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seat.get_pointer(qh, &seat).ok();
        }
    }
    fn remove_capability(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: wl_seat::WlSeat,
        cap: Capability,
    ) {
        if cap == Capability::Keyboard
            && let Some(k) = self.keyboard.take()
        {
            k.release();
        }
        if cap == Capability::Pointer
            && let Some(p) = self.pointer.take()
        {
            p.release();
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

fn key_text(e: &KeyEvent) -> Option<slint::SharedString> {
    let k = match e.keysym {
        Keysym::Return | Keysym::KP_Enter => Key::Return,
        Keysym::Escape => Key::Escape,
        Keysym::Tab => Key::Tab,
        Keysym::ISO_Left_Tab => Key::Backtab,
        Keysym::BackSpace => Key::Backspace,
        Keysym::Left => Key::LeftArrow,
        Keysym::Right => Key::RightArrow,
        Keysym::Up => Key::UpArrow,
        Keysym::Down => Key::DownArrow,
        Keysym::space => Key::Space,
        _ => return e.utf8.as_deref().filter(|t| !t.is_empty()).map(Into::into),
    };
    Some(k.into())
}

impl KeyboardHandler for State {
    fn enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _: u32,
        _: &[u32],
        _: &[Keysym],
    ) {
        self.keyboard_focus = Some(surface.clone());
        if let Some(w) = window_for_surface(surface) {
            w.focused.set(true);
            w.dispatch(WindowEvent::WindowActiveChanged(true));
            w.accesskit.borrow_mut().process_focus_event(true);
        }
    }
    fn leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        surface: &wl_surface::WlSurface,
        _: u32,
    ) {
        self.keyboard_focus = None;
        if let Some(w) = window_for_surface(surface) {
            w.focused.set(false);
            w.dispatch(WindowEvent::WindowActiveChanged(false));
            w.accesskit.borrow_mut().process_focus_event(false);
        }
    }
    fn press_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        e: KeyEvent,
    ) {
        let w = self.keyboard_focus.as_ref().and_then(window_for_surface);
        if let (Some(w), Some(text)) = (w, key_text(&e)) {
            w.dispatch(WindowEvent::KeyPressed { text });
        }
    }
    fn release_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        e: KeyEvent,
    ) {
        let w = self.keyboard_focus.as_ref().and_then(window_for_surface);
        if let (Some(w), Some(text)) = (w, key_text(&e)) {
            w.dispatch(WindowEvent::KeyReleased { text });
        }
    }
    fn update_modifiers(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        _: Modifiers,
        _: u32,
    ) {
    }
}

impl PointerHandler for State {
    fn pointer_frame(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        for e in events {
            let Some(w) = window_for_surface(&e.surface) else {
                continue;
            };
            let position = LogicalPosition::new(e.position.0 as f32, e.position.1 as f32);
            let button = |b| match b {
                0x110 => PointerEventButton::Left,
                0x111 => PointerEventButton::Right,
                0x112 => PointerEventButton::Middle,
                _ => PointerEventButton::Other,
            };
            match e.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    w.dispatch(WindowEvent::PointerMoved { position })
                }
                PointerEventKind::Leave { .. } => w.dispatch(WindowEvent::PointerExited),
                PointerEventKind::Press { button: b, .. } => {
                    w.dispatch(WindowEvent::PointerPressed {
                        position,
                        button: button(b),
                    })
                }
                PointerEventKind::Release { button: b, .. } => {
                    w.dispatch(WindowEvent::PointerReleased {
                        position,
                        button: button(b),
                    })
                }
                PointerEventKind::Axis {
                    horizontal,
                    vertical,
                    ..
                } => w.dispatch(WindowEvent::PointerScrolled {
                    position,
                    delta_x: -horizontal.absolute as f32,
                    delta_y: -vertical.absolute as f32,
                }),
            }
        }
    }
}

impl ProvidesRegistryState for State {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    sctk::registry_handlers![OutputState, SeatState];
}

sctk::delegate_compositor!(State);
sctk::delegate_output!(State);
sctk::delegate_seat!(State);
sctk::delegate_keyboard!(State);
sctk::delegate_pointer!(State);
sctk::delegate_layer!(State);
sctk::delegate_registry!(State);
