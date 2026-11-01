use anyhow::{ensure, Context, Result};
use image::{DynamicImage, RgbaImage};

// JPEG payload header: magic, width, height, capture timestamp, capture epoch,
// bridge encode duration (microseconds). The outer pipe length is not included.
const JPEG_HEADER: usize = 36;

struct JpegFrame<'a> {
    data: &'a [u8],
    dimensions: (u32, u32),
    captured_at: u64,
}

fn jpeg(bytes: &[u8]) -> Result<Option<JpegFrame<'_>>> {
    if !bytes.starts_with(b"JPEG") { return Ok(None); }
    ensure!(bytes.len() >= JPEG_HEADER, "Truncated JPEG bridge header");
    let width = u32::from_le_bytes(bytes[4..8].try_into()?);
    let height = u32::from_le_bytes(bytes[8..12].try_into()?);
    ensure!(matches!((width, height), (1440, 540) | (1920, 720)), "Unexpected JPEG bridge dimensions");
    let data = &bytes[JPEG_HEADER..];
    ensure!(data.ends_with(&[0xff, 0xd9]), "Incomplete bridge JPEG");
    let profile = msi_xpander::jpeg_profile(data)?;
    ensure!((u32::from(profile.width), u32::from(profile.height)) == (width, height),
            "JPEG bridge dimensions differ from encoded image");
    ensure!(profile.sampling == [0x22, 0x11, 0x11], "Bridge JPEG must use baseline 4:2:0 sampling 22 11 11");
    Ok(Some(JpegFrame {
        data, dimensions: (width, height),
        captured_at: u64::from_le_bytes(bytes[12..20].try_into()?),
    }))
}

/// Used only after encode() has validated the complete frame.
pub fn bridge_encode_ms(bytes: &[u8]) -> Option<f64> {
    if bytes.starts_with(b"JPEG") && bytes.len() >= JPEG_HEADER {
        Some(u64::from_le_bytes(bytes[28..36].try_into().ok()?) as f64 / 1000.0)
    } else { None }
}

fn raw(bytes:&[u8])->Result<Option<(u32,u32,u64,&[u8],bool)>> {
    if bytes.starts_with(b"RGBA") || bytes.starts_with(b"BGRA") || bytes.starts_with(b"RGB2") || bytes.starts_with(b"BGR2") {
        let header_size=if bytes.starts_with(b"RGB2") || bytes.starts_with(b"BGR2") {28} else {20};
        ensure!(bytes.len()>=header_size,"Truncated raw frame header");
        let width=u32::from_le_bytes(bytes[4..8].try_into()?);
        let height=u32::from_le_bytes(bytes[8..12].try_into()?);
        let timestamp=u64::from_le_bytes(bytes[12..20].try_into()?);
        ensure!(width>0 && height>0 && width<=3840 && height<=1440,"Invalid raw frame dimensions");
        ensure!(bytes.len()==header_size+width as usize*height as usize*4,"Raw frame length mismatch");
        return Ok(Some((width,height,timestamp,&bytes[header_size..],bytes.starts_with(b"BGRA") || bytes.starts_with(b"BGR2"))));
    }
    Ok(None)
}

pub fn capture_epoch(bytes:&[u8])->Option<u64> {
    if (bytes.len()>=28 && (bytes.starts_with(b"RGB2") || bytes.starts_with(b"BGR2")))
        || (bytes.len()>=JPEG_HEADER && bytes.starts_with(b"JPEG")) {
        Some(u64::from_le_bytes(bytes[20..28].try_into().ok()?))
    } else {None}
}

pub fn decode(bytes: &[u8]) -> Result<(DynamicImage, Option<u64>)> {
    if let Some(frame) = jpeg(bytes)? {
        return Ok((image::load_from_memory(frame.data).context("Decode bridge JPEG")?, Some(frame.captured_at)));
    }
    if let Some((width,height,timestamp,data,bgra))=raw(bytes)? {
        let mut pixels=data.to_vec();
        if bgra { for pixel in pixels.chunks_exact_mut(4) { pixel.swap(0,2); } }
        let image=RgbaImage::from_raw(width,height,pixels).context("Invalid RGBA frame")?;
        return Ok((DynamicImage::ImageRgba8(image),Some(timestamp)));
    }
    Ok((image::load_from_memory(bytes).context("Decode legacy PNG frame")?,None))
}

pub fn encode(bytes:&[u8],quality:u8)->Result<(Vec<u8>,Option<u64>,(u32,u32))> {
    if let Some(frame) = jpeg(bytes)? {
        // The hardware encoder already did the work; validate every frame and
        // pass its bytes through unchanged rather than encoding it again.
        return Ok((frame.data.to_vec(), Some(frame.captured_at), frame.dimensions));
    }
    if let Some((width,height,timestamp,data,bgra))=raw(bytes)? {
        ensure!(matches!((width,height),(1440,540)|(1920,720)),"Unexpected captured desktop dimensions");
        let color=if bgra {jpeg_encoder::ColorType::Bgra} else {jpeg_encoder::ColorType::Rgba};
        return Ok((crate::jpeg420::encode_pixels(data,width,height,color,quality)?,Some(timestamp),(width,height)));
    }
    let (image,time)=decode(bytes)?;
    Ok((crate::jpeg420::encode(&image,quality)?,time,(image.width(),image.height())))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn header(w:u32,h:u32)->Vec<u8> {
        [b"RGBA".as_slice(),&w.to_le_bytes(),&h.to_le_bytes(),&123u64.to_le_bytes()].concat()
    }
    #[test]
    fn raw_channel_order_and_capture_time_are_preserved() {
        let mut bytes=header(2,1);
        bytes.extend_from_slice(&[255,0,0,255,0,0,255,255]);
        let (image,time)=decode(&bytes).unwrap();
        let rgb=image.to_rgb8();
        assert_eq!(rgb.get_pixel(0,0).0,[255,0,0]);
        assert_eq!(rgb.get_pixel(1,0).0,[0,0,255]);
        assert_eq!(time,Some(123));
    }
    #[test]
    fn malformed_raw_frames_are_rejected() {
        for bytes in [b"RGBA".to_vec(),header(1920,720),header(u32::MAX,u32::MAX),header(0,1)] {
            assert!(decode(&bytes).is_err());
        }
    }
    #[test]
    fn wake_epoch_is_preserved_without_becoming_pixel_data() {
        let mut bytes=header(1,1); bytes[..4].copy_from_slice(b"BGR2");
        bytes.extend_from_slice(&7u64.to_le_bytes());
        bytes.extend_from_slice(&[0,0,255,255]);
        assert_eq!(capture_epoch(&bytes),Some(7));
        let (image,time)=decode(&bytes).unwrap();
        assert_eq!(image.to_rgb8().get_pixel(0,0).0,[255,0,0]);
        assert_eq!(time,Some(123));
        assert!(decode(&bytes[..24]).is_err());
    }
    #[test]
    fn bgra_pixels_encode_as_blue_and_red_without_channel_reversal() {
        let mut bytes=header(1440,540); bytes[..4].copy_from_slice(b"BGRA");
        for _ in 0..1440*540 { bytes.extend_from_slice(&[255,0,0,255]); }
        let (jpeg,time,size)=encode(&bytes,85).unwrap();
        let decoded=image::load_from_memory(&jpeg).unwrap().to_rgb8();
        let pixel=decoded.get_pixel(720,270).0;
        assert!(pixel[2]>240 && pixel[0]<15 && pixel[1]<15);
        assert_eq!(time,Some(123)); assert_eq!(size,(1440,540));
    }

    fn vt_frame() -> Vec<u8> {
        let jpeg = include_bytes!("../docs/evidence/2026-10-31-vt-probe-q075.jpg");
        [b"JPEG".as_slice(), &1920u32.to_le_bytes(), &720u32.to_le_bytes(),
         &123u64.to_le_bytes(), &7u64.to_le_bytes(), &2500u64.to_le_bytes(), jpeg].concat()
    }

    #[test]
    fn hardware_jpeg_is_preserved_with_timestamp_epoch_and_encode_duration() {
        let bytes = vt_frame();
        for quality in [1, 55, 95] {
            let (encoded, captured, dimensions) = encode(&bytes, quality).unwrap();
            assert_eq!(encoded, &bytes[JPEG_HEADER..]);
            assert_eq!(captured, Some(123));
            assert_eq!(dimensions, (1920, 720));
        }
        assert_eq!(capture_epoch(&bytes), Some(7));
        assert_eq!(bridge_encode_ms(&bytes), Some(2.5));
        let (image, captured) = decode(&bytes).unwrap();
        assert_eq!((image.width(), image.height()), (1920, 720));
        assert_eq!(captured, Some(123));
    }

    #[test]
    fn hardware_jpeg_format_is_checked_on_every_frame() {
        let good = vt_frame();
        encode(&good, 55).unwrap();
        let sof = good.windows(2).position(|marker| marker == [0xff, 0xc0]).unwrap();
        for (offset, value) in [(1, 0xc2), (4, 12), (9, 4), (11, 0x21)] {
            let mut bad = good.clone();
            bad[sof + offset] = value;
            assert!(encode(&bad, 55).is_err(), "accepted bad SOF offset {offset}");
        }
        let mut mismatch = good.clone();
        mismatch[4..8].copy_from_slice(&1440u32.to_le_bytes());
        mismatch[8..12].copy_from_slice(&540u32.to_le_bytes());
        assert!(encode(&mismatch, 55).is_err());
        let mut wrong_size = good.clone();
        wrong_size[4..8].copy_from_slice(&3840u32.to_le_bytes());
        assert!(encode(&wrong_size, 55).is_err());
        assert!(encode(&good[..good.len()-2], 55).is_err());
        for length in [4, 12, 20, 28, 35, 36] {
            assert!(encode(&good[..length], 55).is_err());
        }
        // A rejected frame must not affect later valid frames.
        assert!(encode(&good, 55).is_ok());
    }

    #[test]
    fn raw_frames_keep_the_local_encode_timing_path() {
        assert_eq!(bridge_encode_ms(&header(1, 1)), None);
        assert_eq!(bridge_encode_ms(b"JPEG"), None);
        assert_eq!(capture_epoch(b"JPEG"), None);
    }
}
