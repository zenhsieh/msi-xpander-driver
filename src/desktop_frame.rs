use anyhow::{ensure, Context, Result};
use image::{DynamicImage, RgbaImage};

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
    if bytes.len()>=28 && (bytes.starts_with(b"RGB2") || bytes.starts_with(b"BGR2")) {
        Some(u64::from_le_bytes(bytes[20..28].try_into().ok()?))
    } else {None}
}

pub fn decode(bytes: &[u8]) -> Result<(DynamicImage, Option<u64>)> {
    if let Some((width,height,timestamp,data,bgra))=raw(bytes)? {
        let mut pixels=data.to_vec();
        if bgra { for pixel in pixels.chunks_exact_mut(4) { pixel.swap(0,2); } }
        let image=RgbaImage::from_raw(width,height,pixels).context("Invalid RGBA frame")?;
        return Ok((DynamicImage::ImageRgba8(image),Some(timestamp)));
    }
    Ok((image::load_from_memory(bytes).context("Decode legacy PNG frame")?,None))
}

pub fn encode(bytes:&[u8],quality:u8)->Result<(Vec<u8>,Option<u64>,(u32,u32))> {
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
}
