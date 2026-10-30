use anyhow::{ensure, Result};
use image::DynamicImage;
use jpeg_encoder::{ColorType, Encoder, SamplingFactor};

pub fn encode(image: &DynamicImage, quality: u8) -> Result<Vec<u8>> {
    let rgb = image.to_rgb8();
    let (width, height) = rgb.dimensions();
    encode_pixels(rgb.as_raw(),width,height,ColorType::Rgb,quality)
}

pub fn encode_pixels(data:&[u8],width:u32,height:u32,color:ColorType,quality:u8)->Result<Vec<u8>> {
    ensure!(width > 0 && height > 0 && width <= u16::MAX as u32 && height <= u16::MAX as u32, "JPEG dimensions out of range");
    let mut out = Vec::new();
    {
        let mut encoder = Encoder::new(&mut out, quality);
        encoder.set_sampling_factor(SamplingFactor::F_2_2);
        encoder.set_progressive(false);
        encoder.set_optimized_huffman_tables(false);
        encoder.encode(data, width as u16, height as u16, color)?;
    }
    let profile = msi_xpander::jpeg_profile(&out)?;
    ensure!(profile.width as u32 == width && profile.height as u32 == height &&
        profile.sampling == [0x22,0x11,0x11], "Encoded JPEG is outside the observed baseline 4:2:0 format");
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn startup_and_full_quality_frames_are_decodable_baseline_420() {
        for (width,height) in [(1920,720),(1440,540)] {
            let rgb = image::RgbImage::from_fn(width,height,|x,y| image::Rgb([(x%256) as u8,(y%256) as u8,125]));
            let source = DynamicImage::ImageRgb8(rgb);
            for quality in [1,85] {
                let bytes = encode(&source,quality).unwrap();
                assert!(bytes.ends_with(&[0xff,0xd9]));
                let decoded = image::load_from_memory(&bytes).unwrap();
                assert_eq!((decoded.width(),decoded.height()),(width,height));
            }
        }
    }
}
