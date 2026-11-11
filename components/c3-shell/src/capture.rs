// SPDX-License-Identifier: MIT OR Apache-2.0
//! Live window previews for the switcher (#266), through the capture interface atos-comp offers
//! to unsandboxed clients: `ext_foreign_toplevel_image_capture_source_manager_v1` turns a
//! window's ext handle (`toplevels.rs`) into a capture source, `ext_image_copy_capture_v1`
//! copies the window into a wl_shm buffer of ours. Who else can use it: card #266, Step 1.
//!
//! Privacy rules (card #266): sessions exist only between `start` and `stop` (the switcher's
//! open and close); frames are read from shared memory (memfd), scaled to tile size at once and
//! handed to the switcher; `stop` destroys every session and frees the buffers. Nothing is
//! written to a file and no pixel data is logged. Without the globals (sway in CI) every tile
//! keeps its placeholder.

use std::cell::RefCell;
use std::time::Duration;

use atos_shell::preview::{self, Buffer, downscale};
use sctk::globals::ProvidesBoundGlobal;
use sctk::reexports::client::globals::GlobalList;
use sctk::reexports::client::protocol::{wl_buffer, wl_shm};
use sctk::reexports::client::{Connection, Dispatch, QueueHandle, WEnum, delegate_noop};
use sctk::reexports::protocols::ext::image_capture_source::v1::client::{
    ext_foreign_toplevel_image_capture_source_manager_v1 as source_manager,
    ext_image_capture_source_v1 as source,
};
use sctk::reexports::protocols::ext::image_copy_capture::v1::client::{
    ext_image_copy_capture_frame_v1 as frame, ext_image_copy_capture_manager_v1 as manager,
    ext_image_copy_capture_session_v1 as session,
};
use sctk::shm::raw::RawPool;

use crate::platform::State;
use crate::toplevels;

/// Time between two frames of one window: live enough for a glance, cheap with ten windows.
// ponytail: fixed rate; tie it to damage events if a video tile ever looks choppy.
const INTERVAL: Duration = Duration::from_millis(250);

type Hook = Box<dyn Fn(u32, slint::Image)>;

struct Capture {
    /// The window (`toplevels::Toplevel::id`).
    id: u32,
    source: source::ExtImageCaptureSourceV1,
    session: session::ExtImageCopyCaptureSessionV1,
    /// Constraints as the session last sent them; used from its next `done`. Untrusted: the
    /// window's client controls its size (`preview::buffer` checks them).
    size: (u32, u32),
    format: Option<wl_shm::Format>,
    /// The next constraint event starts a new batch (after a `done`): forget the old formats.
    fresh: bool,
    /// The buffer and its shape, kept across frames.
    buffer: Option<(RawPool, wl_buffer::WlBuffer, Buffer)>,
    frame: Option<frame::ExtImageCopyCaptureFrameV1>,
    /// A frame was asked for (timer pending or in flight).
    busy: bool,
}

#[derive(Default)]
struct Captures {
    qh: Option<QueueHandle<State>>,
    sources: Option<source_manager::ExtForeignToplevelImageCaptureSourceManagerV1>,
    manager: Option<manager::ExtImageCopyCaptureManagerV1>,
    shm: Option<wl_shm::WlShm>,
    list: Vec<Capture>,
    /// Physical tile size the frames are scaled to.
    target: (u32, u32),
    /// Largest capture accepted, per side: the output's size in the compositor's capture
    /// coordinates (logical pixels).
    max: (u32, u32),
    hook: Option<Hook>,
    /// Counts `stop`s, so a timer from an earlier opening does nothing.
    generation: u32,
    /// Windows whose capture was refused or stopped: not tried again until `stop`.
    refused: Vec<u32>,
}

thread_local! {
    static CAPTURES: RefCell<Captures> = RefCell::default();
}

pub fn bind(globals: &GlobalList, qh: &QueueHandle<State>) {
    CAPTURES.with(|c| {
        let mut c = c.borrow_mut();
        c.qh = Some(qh.clone());
        c.sources = globals.bind(qh, 1..=1, ()).ok();
        c.manager = globals.bind(qh, 1..=1, ()).ok();
        c.shm = globals.bind(qh, 1..=1, ()).ok();
    });
}

/// Starts capturing the windows `ids` that are not captured yet; `hook(id, image)` gets each
/// frame, scaled to cover `target` (physical pixels). A window larger than `max` (logical
/// pixels, the output's size) is not captured. Returns at once: frames arrive later.
pub fn start(
    ids: &[u32],
    target: (u32, u32),
    max: (u32, u32),
    hook: impl Fn(u32, slint::Image) + 'static,
) {
    CAPTURES.with(|c| {
        let c = &mut *c.borrow_mut();
        let (Some(qh), Some(sources), Some(manager), Some(_)) =
            (&c.qh, &c.sources, &c.manager, &c.shm)
        else {
            return;
        };
        c.target = target;
        c.max = max;
        c.hook = Some(Box::new(hook));
        for &id in ids {
            if c.list.iter().any(|x| x.id == id) || c.refused.contains(&id) {
                continue;
            }
            let Some(handle) = toplevels::handle(id) else {
                continue;
            };
            let source = sources.create_source(&handle, qh, ());
            let session = manager.create_session(&source, manager::Options::empty(), qh, id);
            c.list.push(Capture {
                id,
                source,
                session,
                size: (0, 0),
                format: None,
                fresh: false,
                buffer: None,
                frame: None,
                busy: false,
            });
        }
    });
}

/// Ends every session and frees every buffer.
pub fn stop() {
    CAPTURES.with(|c| {
        let c = &mut *c.borrow_mut();
        c.hook = None;
        c.generation += 1;
        c.refused.clear();
        for x in c.list.drain(..) {
            drop_capture(x);
        }
    });
}

fn drop_capture(x: Capture) {
    if let Some(f) = x.frame {
        f.destroy();
    }
    if let Some((_pool, buffer, ..)) = x.buffer {
        buffer.destroy();
    }
    x.session.destroy();
    x.source.destroy();
}

fn remove(id: u32) {
    CAPTURES.with(|c| {
        let mut c = c.borrow_mut();
        if let Some(i) = c.list.iter().position(|x| x.id == id) {
            drop_capture(c.list.remove(i));
            c.refused.push(id);
        }
    });
}

/// Asks for the next frame of window `id`, with a buffer that fits the session's constraints.
/// Constraints the shell refuses (`preview::buffer`), or a buffer it cannot allocate, end the
/// window's session: its tile keeps the placeholder, and nothing reaches the compositor that it
/// would answer with a protocol error (which would disconnect the shell).
fn capture(id: u32) {
    let refused = CAPTURES.with(|c| {
        let c = &mut *c.borrow_mut();
        let max = c.max;
        let (Some(qh), Some(shm)) = (c.qh.clone(), c.shm.clone()) else {
            return false;
        };
        let Some(x) = c.list.iter_mut().find(|x| x.id == id) else {
            return false;
        };
        if x.frame.is_some() {
            return false;
        }
        let Some(format) = x.format else {
            // No usable format offered.
            return true;
        };
        let Some(shape) = preview::buffer(x.size.0, x.size.1, u32::from(format), max) else {
            return true;
        };
        if x.buffer.as_ref().is_none_or(|b| b.2 != shape) {
            if let Some((_, old, _)) = x.buffer.take() {
                old.destroy();
            }
            let Ok(mut pool) = RawPool::new(shape.len, &Shm(shm)) else {
                return true;
            };
            // Each value fits i32: `shape.len` does, and it is the largest.
            let buffer = pool.create_buffer(
                0,
                shape.w as i32,
                shape.h as i32,
                shape.stride as i32,
                format,
                (),
                &qh,
            );
            x.buffer = Some((pool, buffer, shape));
        }
        let Some((_, buffer, _)) = &x.buffer else {
            return true;
        };
        let f = x.session.create_frame(&qh, id);
        f.attach_buffer(buffer);
        f.damage_buffer(0, 0, shape.w as i32, shape.h as i32);
        f.capture();
        x.frame = Some(f);
        x.busy = true;
        false
    });
    if refused {
        remove(id);
    }
}

/// The frame of window `id` is in its buffer: scale it and hand it on, then ask for the next.
fn ready(id: u32) {
    let done = CAPTURES.with(|c| {
        let c = &mut *c.borrow_mut();
        let target = c.target;
        let x = c.list.iter_mut().find(|x| x.id == id)?;
        if let Some(f) = x.frame.take() {
            f.destroy();
        }
        let (pool, _, b) = x.buffer.as_mut()?;
        let b = *b;
        let image = downscale(
            pool.mmap(),
            b.w,
            b.h,
            b.stride,
            b.order,
            b.opaque,
            target.0,
            target.1,
        );
        Some((image?, c.generation))
    });
    let Some((image, generation)) = done else {
        return;
    };
    // Outside the borrow: the hook redraws the switcher.
    let hook = CAPTURES.with(|c| c.borrow_mut().hook.take());
    if let Some(hook) = hook {
        hook(id, image);
        CAPTURES.with(|c| {
            let mut c = c.borrow_mut();
            if c.generation == generation && c.hook.is_none() {
                c.hook = Some(hook);
            }
        });
    }
    later(id, generation);
}

/// Asks for the next frame after `INTERVAL`, unless the switcher closed in between.
fn later(id: u32, generation: u32) {
    slint::Timer::single_shot(INTERVAL, move || {
        let current = CAPTURES.with(|c| {
            let mut c = c.borrow_mut();
            let current = c.generation == generation;
            // A timer from an earlier opening leaves a newer capture of the window alone.
            if current && let Some(x) = c.list.iter_mut().find(|x| x.id == id) {
                x.busy = false;
            }
            current
        });
        if current {
            capture(id);
        }
    });
}

/// `RawPool` wants the shm global through this trait.
struct Shm(wl_shm::WlShm);

impl ProvidesBoundGlobal<wl_shm::WlShm, 1> for Shm {
    fn bound_global(&self) -> Result<wl_shm::WlShm, sctk::error::GlobalError> {
        Ok(self.0.clone())
    }
}

delegate_noop!(State: ignore wl_shm::WlShm);
delegate_noop!(State: ignore wl_buffer::WlBuffer);
delegate_noop!(State: source_manager::ExtForeignToplevelImageCaptureSourceManagerV1);
delegate_noop!(State: manager::ExtImageCopyCaptureManagerV1);
delegate_noop!(State: source::ExtImageCaptureSourceV1);

/// User data: the window's ID.
impl Dispatch<session::ExtImageCopyCaptureSessionV1, u32> for State {
    fn event(
        _: &mut Self,
        _: &session::ExtImageCopyCaptureSessionV1,
        event: session::Event,
        id: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let id = *id;
        // The first constraint event after a `done` starts a new batch: earlier formats go.
        let with = |f: &dyn Fn(&mut Capture)| {
            CAPTURES.with(|c| {
                if let Some(x) = c.borrow_mut().list.iter_mut().find(|x| x.id == id) {
                    if std::mem::take(&mut x.fresh) {
                        x.format = None;
                    }
                    f(x)
                }
            })
        };
        match event {
            session::Event::BufferSize { width, height } => with(&|x| x.size = (width, height)),
            session::Event::ShmFormat {
                format: WEnum::Value(f),
            } => with(&|x| {
                // Formats whose bytes `preview::downscale` reads; the 8-bit RGBA ones first.
                let rank =
                    |f: Option<wl_shm::Format>| f.map_or(0, |f| preview::format_rank(f.into()));
                if rank(Some(f)) > rank(x.format) {
                    x.format = Some(f);
                }
            }),
            // Other formats (unknown codes) are ignored, as are dmabuf constraints.
            session::Event::ShmFormat { .. } => with(&|_| {}),
            // Constraints are complete: the first frame, or a new buffer after a resize.
            session::Event::Done => {
                let idle = CAPTURES.with(|c| {
                    let mut c = c.borrow_mut();
                    let x = c.list.iter_mut().find(|x| x.id == id);
                    x.is_some_and(|x| {
                        x.fresh = true;
                        x.frame.is_none() && !x.busy
                    })
                });
                if idle {
                    capture(id);
                }
            }
            // The window closed, or the compositor will not capture it: the tile keeps its
            // placeholder (or the last frame it got).
            session::Event::Stopped => remove(id),
            _ => {}
        }
    }
}

/// User data: the window's ID.
impl Dispatch<frame::ExtImageCopyCaptureFrameV1, u32> for State {
    fn event(
        _: &mut Self,
        _: &frame::ExtImageCopyCaptureFrameV1,
        event: frame::Event,
        id: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let id = *id;
        match event {
            frame::Event::Ready => ready(id),
            frame::Event::Failed { reason } => {
                let generation = CAPTURES.with(|c| {
                    let mut c = c.borrow_mut();
                    let generation = c.generation;
                    if let Some(x) = c.list.iter_mut().find(|x| x.id == id)
                        && let Some(f) = x.frame.take()
                    {
                        f.destroy();
                        // New constraints follow with a `done`, which asks again.
                        x.busy = reason != WEnum::Value(frame::FailureReason::BufferConstraints);
                    }
                    generation
                });
                match reason {
                    WEnum::Value(frame::FailureReason::Stopped) => remove(id),
                    WEnum::Value(frame::FailureReason::BufferConstraints) => {}
                    _ => later(id, generation),
                }
            }
            _ => {}
        }
    }
}
