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
    if w == 0 || h == 0 || tw == 0 || th == 0 || data.len() < (stride * (h - 1) + w * 4) as usize {
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
        let i = (y * stride + x * 4) as usize;
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
