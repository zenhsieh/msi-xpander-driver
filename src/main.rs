use anyhow::Result;
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
        _ => anyhow::bail!("Commands: verify | probe | show [image.jpg] | show-stream | dashboard [image.jpg] | show420 | show-prime420 | desktop [frames] | kiosk frame.png. Hardware commands need --features hardware."),
    }
}
