//! Qianchen Desk: a small JPEG of the primary screen for the device list's thumbnail view.
//! Taken only when the server asks (someone is looking at the thumbnails) and nobody is
//! connected, so it never competes with a remote session for the capturer.
use hbb_common::{bail, ResultType};
use scrap::{Display, Frame, TraitCapturer, TraitPixelBuffer};
use std::{io::ErrorKind, time::Duration};

const THUMB_WIDTH: usize = 480;

pub fn capture_jpeg() -> ResultType<Vec<u8>> {
    #[cfg(windows)]
    crate::platform::windows::try_change_desktop();
    let display = Display::primary()?;
    let mut capturer = scrap::Capturer::new(display)?;
    for _ in 0..25 {
        match capturer.frame(Duration::from_millis(200)) {
            Ok(Frame::PixelBuffer(pb)) => {
                let (w, h) = (pb.width(), pb.height());
                let stride = pb.stride().first().copied().unwrap_or(w * 4);
                let bgr = matches!(pb.pixfmt(), scrap::Pixfmt::BGRA);
                return encode(pb.data(), w, h, stride, bgr);
            }
            Ok(Frame::Texture(_)) => bail!("texture frame"),
            Err(e) if e.kind() == ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e.into()),
        }
    }
    bail!("no frame")
}

/// Box-filter down to THUMB_WIDTH and encode as JPEG.
fn encode(data: &[u8], w: usize, h: usize, stride: usize, bgr: bool) -> ResultType<Vec<u8>> {
    if w == 0 || h == 0 || data.len() < stride * (h - 1) + w * 4 {
        bail!("bad frame");
    }
    let step = ((w + THUMB_WIDTH - 1) / THUMB_WIDTH).max(1);
    let (tw, th) = (w / step, h / step);
    let mut rgb = Vec::with_capacity(tw * th * 3);
    for ty in 0..th {
        for tx in 0..tw {
            let (mut r, mut g, mut b) = (0u32, 0u32, 0u32);
            for dy in 0..step {
                let row = (ty * step + dy) * stride;
                for dx in 0..step {
                    let i = row + (tx * step + dx) * 4;
                    let (c0, c1, c2) = (data[i] as u32, data[i + 1] as u32, data[i + 2] as u32);
                    if bgr {
                        b += c0;
                        g += c1;
                        r += c2;
                    } else {
                        r += c0;
                        g += c1;
                        b += c2;
                    }
                }
            }
            let n = (step * step) as u32;
            rgb.extend_from_slice(&[(r / n) as u8, (g / n) as u8, (b / n) as u8]);
        }
    }
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 60).encode(
        &rgb,
        tw as u32,
        th as u32,
        image::ColorType::Rgb8,
    )?;
    Ok(out)
}
