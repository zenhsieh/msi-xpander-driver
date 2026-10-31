use anyhow::Result;

fn jpeg_profile_description(jpeg: &[u8]) -> Result<String> {
    let profile = msi_xpander::jpeg_profile(jpeg)?;
    let sampling = profile.sampling.iter().map(|value| format!("{value:02x}"))
        .collect::<Vec<_>>().join(" ");
    // jpeg_profile rejects SOF2 and accepts only a three-component, 8-bit SOF0.
    Ok(format!("width={} height={} sampling={sampling} progressive=no baseline=yes",
               profile.width, profile.height))
}
#[cfg(feature = "hardware")]
mod hardware;
#[cfg(feature = "hardware")]
mod jpeg420;
#[cfg(feature = "hardware")]
mod desktop_frame;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let command = args.get(1).map(String::as_str).unwrap_or("verify");
    match command {
        "jpeg-profile" => {
            let path = args.get(2).ok_or_else(|| anyhow::anyhow!("Usage: jpeg-profile image.jpg"))?;
            let jpeg = std::fs::read(path)?;
            println!("{}", jpeg_profile_description(&jpeg)?);
            Ok(())
        }
        "verify" => {
            let count = msi_xpander::verify_fixtures()?;
            println!("PASS: {count} captured commands, captured RSA proof, and JPEG header. No USB writes.");
            Ok(())
        }
        #[cfg(feature = "hardware")]
        "probe" => hardware::probe(),
        #[cfg(feature = "hardware")]
        "show" => hardware::show(args.get(2).map(std::path::Path::new)),
        #[cfg(feature = "hardware")]
        "show-stream" => hardware::show_stream(),
        #[cfg(feature = "hardware")]
        "dashboard" => hardware::show_dashboard(args.get(2).map(std::path::Path::new)),
        #[cfg(feature = "hardware")]
        "desktop" => hardware::desktop(args.get(2).map(std::path::Path::new)),
        #[cfg(feature = "hardware")]
        "kiosk" => hardware::kiosk(std::path::Path::new(args.get(2).ok_or_else(|| anyhow::anyhow!("Usage: kiosk frame.png"))?)),
        #[cfg(feature = "hardware")]
        "show420" => hardware::show_420(false),
        #[cfg(feature = "hardware")]
        "show-prime420" => hardware::show_420(true),
        _ => anyhow::bail!("Commands: verify | jpeg-profile image.jpg | probe | show [image.jpg] | show-stream | dashboard [image.jpg] | show420 | show-prime420 | desktop [frames] | kiosk frame.png. Hardware commands need --features hardware."),
    }
}

#[cfg(test)]
mod jpeg_profile_cli_tests {
    use super::*;

    #[test]
    fn fixture_profile_reports_dimensions_sampling_and_baseline() {
        assert_eq!(jpeg_profile_description(include_bytes!("../assets/dashboard-prime.jpg")).unwrap(),
                   "width=1440 height=540 sampling=22 11 11 progressive=no baseline=yes");
    }

    #[test]
    fn progressive_frame_header_is_rejected() {
        let mut jpeg = vec![0xff, 0xd8];
        jpeg.extend_from_slice(include_bytes!("../fixtures/official-jpeg-sof0.bin"));
        jpeg[3] = 0xc2;
        assert!(jpeg_profile_description(&jpeg).unwrap_err().to_string().contains("Progressive"));
    }
}
