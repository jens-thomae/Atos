// SPDX-License-Identifier: MIT OR Apache-2.0
//! Window previews for the switcher (#266): a captured window frame, scaled down to tile size.
//! Pure, so it is tested without a display. The capture itself is `capture.rs` in the binary.

use slint::{Image, Rgba8Pixel, SharedPixelBuffer};

/// Byte order of one captured pixel in memory (wl_shm formats are little-endian words).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Order {
    /// `abgr8888` / `xbgr8888`: R, G, B, A.
    Rgba,
    /// `argb8888` / `xrgb8888`: B, G, R, A.
    Bgra,
}

/// Hard limits on a capture buffer, whatever the output: a side, and the bytes of one buffer.
/// The shell holds one buffer per window while the switcher is open.
pub const MAX_SIDE: u32 = 8192;
pub const MAX_BYTES: u64 = 64 << 20;

/// The shared-memory buffer the shell will allocate for one capture, decided by `buffer`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Buffer {
    pub w: u32,
    pub h: u32,
    /// Bytes per row: `w * 4`.
    pub stride: u32,
    /// Bytes of the whole buffer; fits a wl_shm pool size (`i32`).
    pub len: usize,
    /// The wl_shm format code, one of the four 8-bit RGB formats.
    pub format: u32,
    pub order: Order,
    pub opaque: bool,
}

// wl_shm format codes (wayland.xml): the only ones the shell reads.
const ARGB8888: u32 = 0;
const XRGB8888: u32 = 1;
const ABGR8888: u32 = 0x3432_4241;
const XBGR8888: u32 = 0x3432_4258;

/// Preference among the formats a capture session offers: higher is better, 0 = unusable.
pub fn format_rank(format: u32) -> u8 {
    match format {
        ABGR8888 | XBGR8888 => 2,
        ARGB8888 | XRGB8888 => 1,
        _ => 0,
    }
}

/// Decides the buffer for a capture of `w`×`h` pixels in `format`. All three come from the
/// compositor's session constraints, and the window's own client controls its size (#266
/// review: a 1×1 buffer with a huge viewport, or a far-away subsurface), so they are untrusted.
/// `None` (the tile keeps its placeholder) when a side is 0 or above `max` (the output's size,
/// clamped to `MAX_SIDE`), when the bytes are above `MAX_BYTES` or the format is not one of the
/// four 8-bit RGB ones. The protocol has no way to ask for a smaller buffer: the client must
/// attach one of exactly `w`×`h`, so the only safe answer to a large window is not to capture it.
pub fn buffer(w: u32, h: u32, format: u32, max: (u32, u32)) -> Option<Buffer> {
    let (order, opaque) = match format {
        ABGR8888 => (Order::Rgba, false),
        XBGR8888 => (Order::Rgba, true),
        ARGB8888 => (Order::Bgra, false),
        XRGB8888 => (Order::Bgra, true),
        _ => return None,
    };
    if w == 0 || h == 0 || w > max.0.min(MAX_SIDE) || h > max.1.min(MAX_SIDE) {
        return None;
    }
    let stride = w.checked_mul(4)?;
    let len = u64::from(stride).checked_mul(u64::from(h))?;
    if len > MAX_BYTES || len > i32::MAX as u64 {
        return None;
    }
    Some(Buffer {
        w,
        h,
        stride,
        len: usize::try_from(len).ok()?,
        format,
        order,
        opaque,
    })
}

/// A frame of `w`×`h` pixels (`stride` bytes per row), scaled so it covers `tw`×`th` (the tile
/// keeps the aspect ratio and crops), never up. `opaque`: the format's fourth byte is padding.
/// Each output pixel averages 2×2 samples of its footprint: cheap enough for the event loop
/// (about four reads per output pixel, whatever the window size).
// ponytail: 2×2 samples, not a full box filter; fine text in a large window may alias a little.
#[allow(clippy::too_many_arguments)]
pub fn downscale(
    data: &[u8],
    w: u32,
    h: u32,
    stride: u32,
    order: Order,
    opaque: bool,
    tw: u32,
    th: u32,
) -> Option<Image> {
    if w == 0 || h == 0 || tw == 0 || th == 0 {
        return None;
    }
    // Untrusted sizes: every row must hold `w` pixels and every byte read must be in `data`.
    let row = u64::from(w) * 4;
    let needed = u64::from(stride) * (u64::from(h) - 1) + row;
    if u64::from(stride) < row || needed > data.len() as u64 {
        return None;
    }
    let s = (tw as f32 / w as f32).max(th as f32 / h as f32).min(1.);
    let (ow, oh) = (
        ((w as f32 * s).round() as u32).max(1),
        ((h as f32 * s).round() as u32).max(1),
    );
    let mut out = SharedPixelBuffer::<Rgba8Pixel>::new(ow, oh);
    let (fx, fy) = (w as f32 / ow as f32, h as f32 / oh as f32);
    let px = |x: u32, y: u32| {
        // In bounds: `needed` above, computed without overflow, is at most `data.len()`.
        let i = y as usize * stride as usize + x as usize * 4;
        let p = &data[i..i + 4];
        let (r, g, b) = match order {
            Order::Rgba => (p[0], p[1], p[2]),
            Order::Bgra => (p[2], p[1], p[0]),
        };
        [
            r as u32,
            g as u32,
            b as u32,
            if opaque { 255 } else { p[3] as u32 },
        ]
    };
    for (i, o) in out.make_mut_slice().iter_mut().enumerate() {
        let (ox, oy) = (i as u32 % ow, i as u32 / ow);
        let mut sum = [0u32; 4];
        for (dx, dy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            let x = (((ox as f32 + dx) * fx) as u32).min(w - 1);
            let y = (((oy as f32 + dy) * fy) as u32).min(h - 1);
            let p = px(x, y);
            for c in 0..4 {
                sum[c] += p[c];
            }
        }
        *o = Rgba8Pixel {
            r: (sum[0] / 4) as u8,
            g: (sum[1] / 4) as u8,
            b: (sum[2] / 4) as u8,
            a: (sum[3] / 4) as u8,
        };
    }
    // The compositor renders with premultiplied alpha (window shadows, rounded corners).
    Some(Image::from_rgba8_premultiplied(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_to_cover_the_tile_and_reorders_channels() {
        // 8×4 pixels, BGRA, left half red, right half blue, padding byte 0.
        let mut data = Vec::new();
        for _y in 0..4 {
            for x in 0..8 {
                data.extend_from_slice(if x < 4 {
                    &[0, 0, 255, 0]
                } else {
                    &[255, 0, 0, 0]
                });
            }
        }
        let img = downscale(&data, 8, 4, 32, Order::Bgra, true, 2, 2).unwrap();
        // Covers 2×2 with the aspect ratio kept: 4×2.
        assert_eq!((img.size().width, img.size().height), (4, 2));
        let px = img.to_rgba8_premultiplied().unwrap();
        let px = px.as_slice();
        assert_eq!((px[0].r, px[0].b, px[0].a), (255, 0, 255));
        assert_eq!((px[3].r, px[3].b, px[3].a), (0, 255, 255));
    }

    const MAX: (u32, u32) = (3840, 2160);

    #[test]
    fn buffer_refuses_hostile_sizes_and_formats() {
        let ok = buffer(1280, 800, ABGR8888, MAX).unwrap();
        assert_eq!((ok.stride, ok.len), (5120, 1280 * 800 * 4));
        assert_eq!((ok.order, ok.opaque), (Order::Rgba, false));
        assert_eq!(
            buffer(3840, 2160, XRGB8888, MAX).unwrap().len,
            3840 * 2160 * 4
        );
        // Zero sides.
        assert!(buffer(0, 800, ABGR8888, MAX).is_none());
        assert!(buffer(1280, 0, ABGR8888, MAX).is_none());
        // Larger than the output, or than the hard limits whatever the output.
        assert!(buffer(3841, 100, ABGR8888, MAX).is_none());
        assert!(buffer(100, 2161, ABGR8888, MAX).is_none());
        assert!(buffer(8193, 1, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        assert!(buffer(8192, 8192, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        // The review's cases: 2.4 GB (over i32), and products that overflow u32.
        assert!(buffer(30000, 20000, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        assert!(buffer(40000, 40000, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        assert!(buffer(u32::MAX, u32::MAX, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        assert!(buffer(1 << 30, 1, ABGR8888, (u32::MAX, u32::MAX)).is_none());
        // Unknown and 10-bit formats.
        assert!(buffer(1280, 800, 0x3033_5241, MAX).is_none()); // AR30: argb2101010, 10-bit
        assert!(buffer(1280, 800, 7, MAX).is_none());
        assert_eq!(format_rank(7), 0);
        assert!(format_rank(XBGR8888) > format_rank(ARGB8888));
    }

    #[test]
    fn downscale_refuses_hostile_strides_and_lengths() {
        let data = vec![0u8; 64];
        // Stride shorter than a row.
        assert!(downscale(&data, 4, 4, 8, Order::Rgba, true, 1, 1).is_none());
        // Rows that run past the data.
        assert!(downscale(&data, 4, 4, 20, Order::Rgba, true, 1, 1).is_none());
        // Sizes whose products overflow u32 must not wrap into a passing check.
        assert!(downscale(&data, u32::MAX, 2, u32::MAX, Order::Rgba, true, 1, 1).is_none());
        assert!(downscale(&data, 1, u32::MAX, 1 << 30, Order::Rgba, true, 1, 1).is_none());
        assert!(downscale(&data, 1 << 30, 1, 4, Order::Rgba, true, 1, 1).is_none());
        // A longer stride than needed is fine.
        assert!(downscale(&data, 2, 4, 16, Order::Rgba, true, 1, 1).is_some());
    }

    #[test]
    fn never_scales_up_and_refuses_short_buffers() {
        let data = [1, 2, 3, 4];
        let img = downscale(&data, 1, 1, 4, Order::Rgba, false, 100, 100).unwrap();
        assert_eq!(img.size().width, 1);
        assert_eq!(img.to_rgba8_premultiplied().unwrap().as_slice()[0].a, 4);
        assert!(downscale(&data, 2, 1, 8, Order::Rgba, false, 1, 1).is_none());
        assert!(downscale(&data, 0, 1, 4, Order::Rgba, false, 1, 1).is_none());
    }
}
