use anyhow::{bail, ensure, Context as _, Result};
use hidapi::{HidApi, HidDevice};
use image::{codecs::jpeg::JpegEncoder, DynamicImage, Rgb, RgbImage};
use msi_xpander::{authenticate, dashboard_image_reports, decode_control, hid_report, jpeg_profile, send_jpeg, Transport, PID_DISPLAY, PID_HID, VID};
use rusb::{Context, Device, DeviceHandle, TransferType, UsbContext};
use std::{path::Path, thread, time::{Duration, Instant}};

const TIMEOUT: Duration = Duration::from_secs(5);

fn matching(context: &Context, pid: u16) -> Result<Vec<Device<Context>>> {
    let mut result = Vec::new();
    for device in context.devices()?.iter() {
        let Ok(desc) = device.device_descriptor() else { continue; };
        if desc.vendor_id() == VID && desc.product_id() == pid { result.push(device); }
    }
    Ok(result)
}

fn unique(context: &Context, pid: u16) -> Result<Option<Device<Context>>> {
    let mut found = matching(context, pid)?;
    ensure!(found.len() <= 1, "More than one matching MSI device. Connect only the test panel.");
    Ok(found.pop())
}

pub fn probe() -> Result<()> {
    let context = Context::new().context("Initialize libusb")?;
    let mut count = 0;
    for pid in [PID_HID, PID_DISPLAY] {
        for device in matching(&context, pid)? {
            println!("Found {VID:04x}:{pid:04x}, bus {}, address {}", device.bus_number(), device.address());
            count += 1;
        }
    }
    if count == 0 { println!("No 0db0:7920 or 0db0:7885 device found. Check the panel USB data connection."); }
    println!("Probe completed without USB writes or serial-number reads.");
    Ok(())
}

fn control_text(path: &str, sequence: u32, body: Option<&str>) -> String {
    let mut text = format!("POST {path} 1\r\nSeqNumber={sequence}\r\nContentType=json");
    if let Some(body) = body {
        text.push_str(&format!("\r\nContentLength={}\r\n\r\n{body}", body.len()));
    }
    text
}

fn hid_command(device: &HidDevice, path: &str, sequence: u32, body: Option<&str>, await_ack: bool) -> Result<()> {
    let report = hid_report(&control_text(path, sequence, body))?;
    let written = device.write(&report).with_context(|| format!("Write HID command {path}"))?;
    ensure!(written == 1024 || written == 1025, "Short HID write for {path}: {written}");
    if !await_ack { return Ok(()); }
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut reply = [0u8; 1025];
    while Instant::now() < deadline {
        let len = device.read_timeout(&mut reply, 1000).with_context(|| format!("Read HID acknowledgement for {path}"))?;
        if len == 0 { continue; }
        let wire = if reply[0] == 0 && len > 1 { &reply[1..len] } else { &reply[..len] };
        let text = decode_control(wire).with_context(|| format!("Decode {path} acknowledgement"))?;
        if !text.contains(&format!("AckNumber={}\r\n", sequence + 1)) && !text.ends_with(&format!("AckNumber={}", sequence + 1)) { continue; }
        ensure!(text.lines().next().unwrap_or("").ends_with(" 200"), "Device rejected HID command {path}");
        return Ok(());
    }
    bail!("No matching acknowledgement for HID command {path}")
}

fn switch_to_extended(context: &Context, diagnostic: bool, prime: bool) -> Result<()> {
    if unique(context, PID_DISPLAY)?.is_some() { return Ok(()); }
    ensure!(unique(context, PID_HID)?.is_some(), "MSI panel is not connected");
    let api = HidApi::new().context("Initialize HIDAPI")?;
    let candidates: Vec<_> = api.device_list().filter(|d| {
        d.vendor_id() == VID && d.product_id() == PID_HID && d.usage_page() == 0xff00 && d.usage() == 1
    }).collect();
    ensure!(candidates.len() == 1, "Expected one vendor HID interface (usage page ff00, usage 1); found {}. Keyboard interfaces will not be opened.", candidates.len());
    let device = candidates[0].open_device(&api).context("Open MSI vendor HID interface")?;
    hid_command(&device, "conn", 100, None, true)?;
    hid_command(&device, "power", 114, Some(r#"{"event":"resume"}"#), true)?;
    if diagnostic {
        hid_command(&device, "brightness", 100, Some(r#"{"value":79}"#), true)?;
        println!("Brightness 79 acknowledged by the panel");
    }
    if prime { prime_dashboard(&device, false, None)?; }
    hid_command(&device, "realtimeDisplay", 112, Some(r#"{"enable":false}"#), true)?;
    hid_command(&device, "extendedDisplay", 110, Some(r#"{"enable":true}"#), false)?;
    drop(device);
    println!("Mode-switch command sent; waiting for 0db0:7885");
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if unique(context, PID_DISPLAY)?.is_some() { return Ok(()); }
        thread::sleep(Duration::from_millis(250));
    }
    bail!("The panel did not re-enumerate as 0db0:7885 within 15 seconds")
}

fn prime_dashboard(device: &HidDevice, generated: bool, path: Option<&Path>) -> Result<()> {
    hid_command(device, "brightness", 100, Some(r#"{"value":79}"#), true)?;
    hid_command(device, "realtimeDisplay", 112, Some(r#"{"enable":true}"#), true)?;
    println!("Dashboard enable acknowledged; waiting 4.5 seconds");
    thread::sleep(Duration::from_millis(4500));
    let jpeg = if let Some(path) = path {
        let image = image::open(path).with_context(|| format!("Open {}", path.display()))?
            .resize_exact(1440, 540, image::imageops::FilterType::Lanczos3);
        println!("Dashboard source image: {}", path.display());
        crate::jpeg420::encode(&image, 85)?
    } else if generated {
        let pattern = DynamicImage::ImageRgb8(test_pattern()).resize_exact(1440, 540, image::imageops::FilterType::Lanczos3);
        crate::jpeg420::encode(&pattern, 85)?
    } else {
        include_bytes!("../assets/dashboard-prime.jpg").to_vec()
    };
    let profile = jpeg_profile(&jpeg)?;
    ensure!((profile.width, profile.height) == (1440,540) && profile.sampling == [0x22,0x11,0x11],
        "Dashboard JPEG must be baseline 1440x540 4:2:0");
    let reports = dashboard_image_reports(&jpeg)?;
    for round in 1..=3 {
        for report in &reports {
            let count = device.write(report).context("Write Dashboard image report")?;
            ensure!(count == 1024 || count == 1025, "Short Dashboard write: {count}");
            thread::sleep(Duration::from_millis(1));
        }
        println!("Dashboard image round {round} written ({} reports)", reports.len());
        thread::sleep(Duration::from_millis(250));
    }
    println!("USB writes completed; confirm the physical panel image separately.");
    Ok(())
}

pub fn show_dashboard(path: Option<&Path>) -> Result<()> {
    ensure!(cfg!(any(target_os="windows", target_os="macos")), "Dashboard sending supports Windows and macOS");
    #[cfg(target_os="windows")]
    {
        let output = std::process::Command::new("tasklist.exe").args(["/FO","CSV","/NH"]).output()
            .context("Check official MSI processes")?;
        ensure!(output.status.success(), "Cannot verify official MSI processes are closed");
        let processes = String::from_utf8_lossy(&output.stdout).to_ascii_lowercase();
        ensure!(!processes.contains("\"msi viewxpander.exe\"") && !processes.contains("\"msi viewxpander service.exe\""),
            "Close MSI ViewXpander and its background service through the official controls before independent testing");
    }
    let api = HidApi::new().context("Initialize HIDAPI")?;
    let candidates: Vec<_> = api.device_list().filter(|d| {
        d.vendor_id() == VID && d.product_id() == PID_HID && d.usage_page() == 0xff00 && d.usage() == 1
    }).collect();
    ensure!(candidates.len() == 1, "Expected exactly one Dashboard vendor HID interface; found {}. Reconnect in default mode.", candidates.len());
    let device = candidates[0].open_device(&api).context("Open Dashboard vendor HID")?;
    hid_command(&device, "conn", 100, None, true)?;
    hid_command(&device, "power", 114, Some(r#"{"event":"resume"}"#), true)?;
    prime_dashboard(&device, true, path)?;
    println!("Check the panel for the selected image. Holding 15 seconds.");
    thread::sleep(Duration::from_secs(15));
    Ok(())
}

struct UsbTransport { handle: DeviceHandle<Context> }

// A child owns the virtual display. Releasing it removes that display as well.
struct DesktopBridge(std::process::Child);
impl Drop for DesktopBridge {
    fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
}

fn connect_dashboard() -> Result<HidDevice> {
    let api=HidApi::new().context("Initialize HIDAPI")?;
    let candidates:Vec<_>=api.device_list().filter(|d|d.vendor_id()==VID && d.product_id()==PID_HID && d.usage_page()==0xff00 && d.usage()==1).collect();
    ensure!(candidates.len()==1,"Waiting for one Xpander Dashboard HID interface; found {}",candidates.len());
    let device=candidates[0].open_device(&api).context("Open Dashboard vendor HID")?;
    hid_command(&device,"conn",100,None,true)?;
    hid_command(&device,"power",114,Some(r#"{"event":"resume"}"#),true)?;
    prime_dashboard(&device,true,None)?;
    eprintln!("Dashboard USB session ready/reconnected");
    Ok(device)
}

/// Send an atomically replaced PNG directly, without a virtual display or capture.
pub fn kiosk(path: &Path) -> Result<()> {
    let mut device = None;
    let mut previous = Vec::new();
    let mut last_send = Instant::now();
    loop {
        let attempt = (|| -> Result<()> {
            let png = std::fs::read(path).context("Read kiosk frame")?;
            // Periodic refresh also detects USB disconnects while the picture is static.
            if png == previous && last_send.elapsed() < Duration::from_secs(5) { return Ok(()); }
            let image = image::load_from_memory(&png).context("Decode kiosk PNG")?;
            ensure!(image.width() == 1920 && image.height() == 720, "Kiosk image must be 1920x720");
            let jpeg = crate::jpeg420::encode(&image, 85)?;
            if device.is_none() { device = Some(connect_dashboard()?); }
            let started = Instant::now();
            for report in dashboard_image_reports(&jpeg)? {
                let written = device.as_ref().unwrap().write(&report).context("Send kiosk frame")?;
                ensure!(written == 1024 || written == 1025, "Short kiosk write: {written}");
            }
            eprintln!("Kiosk 1920x720: {} JPEG bytes; USB {:.1}ms", jpeg.len(), started.elapsed().as_secs_f64()*1000.0);
            previous = png;
            last_send = Instant::now();
            Ok(())
        })();
        if let Err(error) = attempt {
            eprintln!("Kiosk waiting/reconnecting: {error:#}");
            device = None;
            previous.clear();
            thread::sleep(Duration::from_secs(2));
        }
        thread::sleep(Duration::from_millis(250));
    }
}

pub fn desktop(helper: Option<&Path>) -> Result<()> {
    use std::io::Read;
    ensure!(cfg!(target_os="macos"), "Desktop bridge requires macOS");
    let default = std::path::PathBuf::from(std::env::var("HOME")?)
        .join("Applications/MSI Xpander Desktop.app/Contents/MacOS/MSIXpanderDesktop");
    let mut bridge = DesktopBridge(std::process::Command::new(helper.unwrap_or(&default))
        .stdout(std::process::Stdio::piped()).spawn().context("Start macOS desktop bridge (build with bash macos/build-bridge.sh)")?);
    let mut input = bridge.0.stdout.take().context("Open desktop frame pipe")?;
    // Read one frame before touching USB: a missing screen-recording permission
    // or virtual-display failure must not alter the panel's mode.
    let read_frame = |input: &mut std::process::ChildStdout| -> Result<Vec<u8>> {
        let mut header = [0u8;4];
        input.read_exact(&mut header).context("Desktop capture ended; inspect bridge errors above (screen-recording permission may be required)")?;
        let length = u32::from_le_bytes(header) as usize;
        ensure!(length > 0 && length <= 16*1024*1024, "Invalid desktop frame size: {length}");
        let mut bytes = vec![0u8;length]; input.read_exact(&mut bytes)?; Ok(bytes)
    };
    let first_frame = read_frame(&mut input)?;
    crate::desktop_frame::decode(&first_frame)?;
    let bridge_jpeg = first_frame.starts_with(b"JPEG");
    let jpeg_quality:u8=std::env::var("MSI_DESKTOP_JPEG_QUALITY").unwrap_or_else(|_| "55".into()).parse().context("Invalid MSI_DESKTOP_JPEG_QUALITY")?;
    ensure!((20..=95).contains(&jpeg_quality), "JPEG quality must be between 20 and 95");
    // Drain capture continuously into one replaceable slot. A slow USB frame
    // drops older captures instead of making the pointer trail behind.
    struct EncodedFrame { jpeg:Vec<u8>, captured_at:Option<u64>, epoch:Option<u64>, dimensions:(u32,u32), encode_ms:f64 }
    #[derive(Default)]
    struct Latest { frame: Option<EncodedFrame>, error: Option<String>, dropped:u64 }
    let latest=std::sync::Arc::new((std::sync::Mutex::new(Latest::default()),std::sync::Condvar::new()));
    let receiver=latest.clone();
    thread::spawn(move || {
      let mut first=Some(first_frame);
      loop {
        let result=(|| -> Result<EncodedFrame> {
            let frame=if let Some(frame)=first.take() { frame } else { read_frame(&mut input)? };
            let stage=Instant::now();
            let (jpeg,captured_at,dimensions)=crate::desktop_frame::encode(&frame,jpeg_quality)?;
            let encode_ms=crate::desktop_frame::bridge_encode_ms(&frame)
                .unwrap_or_else(|| stage.elapsed().as_secs_f64()*1000.0);
            Ok(EncodedFrame {jpeg,captured_at,epoch:crate::desktop_frame::capture_epoch(&frame),dimensions,encode_ms})
        })();
        let (lock,ready)=&*receiver;
        let mut slot=lock.lock().unwrap();
        match result {
            Ok(frame)=> { if slot.frame.replace(frame).is_some() { slot.dropped+=1; } }
            Err(error)=> { slot.error=Some(format!("{error:#}")); ready.notify_one(); break; }
        }
        ready.notify_one();
      }
    });
    let next_frame=|| -> Result<(EncodedFrame,u64)> {
        let (lock,ready)=&*latest;
        let mut slot=lock.lock().unwrap();
        loop {
            if let Some(error)=slot.error.take() { bail!("Desktop capture ended: {error}"); }
            if let Some(frame)=slot.frame.take() { return Ok((frame,slot.dropped)); }
            slot=ready.wait(slot).unwrap();
        }
    };
    let mut device:Option<HidDevice>=None;
    let mut usb_epoch=None;
    let mut retry_after=Instant::now();
    let start = Instant::now(); let mut count = 0u64;
    let report_delay_us: u64 = std::env::var("MSI_LIVE_REPORT_DELAY_US").unwrap_or_else(|_| "0".into()).parse().context("Invalid MSI_LIVE_REPORT_DELAY_US")?;
    ensure!(report_delay_us <= 10_000, "Report delay must be at most 10000 microseconds");
    let mut timing = Instant::now();
    let mut encode_ms=0.0; let mut usb_ms=0.0; let mut batch=0u32;
    eprintln!("Live transport pacing: {report_delay_us} microseconds per report");
    if bridge_jpeg {
        eprintln!("Live JPEG quality: VT {} (bridge JPEG passthrough); native output dimensions retained",
            std::env::var("MSI_VT_QUALITY").unwrap_or_else(|_| "0.75".into()));
    } else {
        eprintln!("Live JPEG quality: {jpeg_quality}; native output dimensions retained");
    }
    loop {
        let (frame,dropped)=next_frame()?;
        let EncodedFrame {jpeg,captured_at,epoch,dimensions,encode_ms:work_ms}=frame;
        if epoch!=usb_epoch {
            eprintln!("Capture epoch changed to {epoch:?}; refresh USB session after wake/recovery");
            usb_epoch=epoch; device=None;
        }
        if device.is_none() {
            if Instant::now()<retry_after {thread::sleep(Duration::from_millis(100));continue;}
            retry_after=Instant::now()+Duration::from_secs(2);
            match connect_dashboard() {
                Ok(connected)=> { device=Some(connected); timing=Instant::now(); batch=0; encode_ms=0.0; usb_ms=0.0; }
                Err(error)=> eprintln!("USB reconnect pending; virtual display retained: {error:#}"),
            }
            // Initialization takes several seconds: send the newest frame next.
            continue;
        }
        if count==0 {eprintln!("Captured desktop output: {}x{} pixels; JPEG worker overlaps USB sending",dimensions.0,dimensions.1);}
        encode_ms+=work_ms;
        let stage=Instant::now();
        let sent=(||->Result<()> {
            let connected=device.as_ref().context("USB session unavailable")?;
            for report in dashboard_image_reports(&jpeg)? {
                let written=connected.write(&report).context("Send live Dashboard frame")?;
                ensure!(written==1024 || written==1025,"Short live Dashboard write: {written}");
                if report_delay_us>0 {thread::sleep(Duration::from_micros(report_delay_us));}
            }
            Ok(())
        })();
        if let Err(error)=sent {
            eprintln!("USB session interrupted; retaining virtual desktop and retrying: {error:#}");
            device=None; retry_after=Instant::now()+Duration::from_secs(1); continue;
        }
        count+=1;
        usb_ms+=stage.elapsed().as_secs_f64()*1000.0; batch+=1;
        if count==1 || count%20==0 {
            let now=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_micros() as u64;
            let age_ms=captured_at.map(|time|now.saturating_sub(time) as f64/1000.0);
            eprintln!("Live desktop: {count} frames, {:.2} fps, {} JPEG bytes, capture-to-send age {age_ms:?} ms, {dropped} old captures dropped", count as f64/start.elapsed().as_secs_f64(),jpeg.len());
        }
        if batch==20 {
            eprintln!("Recent throughput (includes idle gaps): {:.2} fps; mean JPEG worker {:.1}ms, USB {:.1}ms per frame (overlapping stages)",batch as f64/timing.elapsed().as_secs_f64(),encode_ms/batch as f64,usb_ms/batch as f64);
            timing=Instant::now(); encode_ms=0.0; usb_ms=0.0; batch=0;
        }
    }
}

impl Transport for UsbTransport {
    fn control_read(&mut self, rt:u8, r:u8, v:u16, i:u16, data:&mut[u8]) -> Result<usize> {
        Ok(self.handle.read_control(rt, r, v, i, data, TIMEOUT)?)
    }
    fn control_write(&mut self, rt:u8, r:u8, v:u16, i:u16, data:&[u8]) -> Result<usize> {
        Ok(self.handle.write_control(rt, r, v, i, data, TIMEOUT)?)
    }
    fn bulk_out(&mut self, data:&[u8]) -> Result<usize> { Ok(self.handle.write_bulk(0x01, data, TIMEOUT)?) }
    fn bulk_in(&mut self, data:&mut[u8]) -> Result<usize> { Ok(self.handle.read_bulk(0x81, data, TIMEOUT)?) }
}

fn open_display(context: &Context) -> Result<UsbTransport> {
    let device = unique(context, PID_DISPLAY)?.context("Display-mode MSI device not found")?;
    let handle = device.open().context("Open MSI display device")?;
    let config = handle.active_configuration()?;
    if config == 0 { handle.set_active_configuration(1)?; }
    else { ensure!(config == 1, "Unexpected USB configuration: {config}"); }
    let config = device.active_config_descriptor()?;
    let mut valid_interface = false;
    for interface in config.interfaces() {
        for alt in interface.descriptors() {
            if alt.interface_number() != 0 || alt.setting_number() != 0 { continue; }
            let endpoints: Vec<_> = alt.endpoint_descriptors().filter(|e| e.transfer_type() == TransferType::Bulk).map(|e| e.address()).collect();
            valid_interface = alt.class_code() == 0xff && endpoints.contains(&0x01) && endpoints.contains(&0x81);
        }
    }
    ensure!(valid_interface, "USB interface does not match the recorded bulk display protocol");
    handle.claim_interface(0).context("Claim vendor interface 0. This prototype does not detach drivers or alter security settings.")?;
    Ok(UsbTransport { handle })
}

fn test_pattern() -> RgbImage {
    let bars = [[230,55,55], [240,170,30], [230,225,50], [45,200,100], [45,150,225], [130,80,220]];
    RgbImage::from_fn(1920, 720, |x,y| {
        if y < 240 { Rgb(bars[(x / 320) as usize]) }
        else if y < 480 { let gray = (x * 255 / 1919) as u8; Rgb([gray, gray, gray]) }
        else { let on = ((x / 60) + (y / 60)) % 2 == 0; Rgb(if on { [240,240,240] } else { [20,20,20] }) }
    })
}

fn jpeg(image: &DynamicImage, quality: u8) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality).encode_image(image)?;
    Ok(out)
}

pub fn show(path: Option<&Path>) -> Result<()> {
    show_internal(path, false, false, false)
}

pub fn show_stream() -> Result<()> {
    show_internal(None, true, false, false)
}

pub fn show_420(prime: bool) -> Result<()> {
    show_internal(None, true, true, prime)
}

fn show_internal(path: Option<&Path>, diagnostic: bool, use_420: bool, prime: bool) -> Result<()> {
    ensure!(cfg!(target_os = "macos"), "Hardware sending is currently enabled only on macOS; do not replace the Windows MSI driver");
    let image = if let Some(path) = path {
        DynamicImage::ImageRgb8(image::open(path).with_context(|| format!("Open {}", path.display()))?.resize_exact(1920,720,image::imageops::FilterType::Lanczos3).to_rgb8())
    } else { DynamicImage::ImageRgb8(test_pattern()) };
    let initial = if use_420 { crate::jpeg420::encode(&image, 1)? } else { jpeg(&image, 1)? };
    let full = if use_420 { crate::jpeg420::encode(&image, 85)? } else { jpeg(&image, 85)? };
    println!("JPEG mode: {}; Dashboard priming: {prime}", if use_420 {"baseline 4:2:0"} else {"original image encoder"});
    let context = Context::new()?;
    if prime { ensure!(unique(&context, PID_HID)?.is_some(), "Priming requires a freshly reconnected Dashboard-mode panel"); }
    switch_to_extended(&context, diagnostic, prime)?;
    let mut transport = open_display(&context)?;
    authenticate(&mut transport, &mut |stage| println!("{stage}"))?;
    send_jpeg(&mut transport, &initial, 0x100000)?;
    thread::sleep(Duration::from_millis(50));
    send_jpeg(&mut transport, &full, 0x100001)?;
    if diagnostic {
        println!("Streaming the colour bars for 20 seconds, then holding the USB connection for 10 seconds");
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut sequence = 0x100002;
        while Instant::now() < deadline {
            thread::sleep(Duration::from_millis(100));
            send_jpeg(&mut transport, &full, sequence)
                .with_context(|| format!("Send diagnostic frame sequence {sequence:#x}"))?;
            sequence += 1;
        }
        println!("{} JPEG frames transferred; holding connection for 10 seconds", sequence - 0x100000);
        thread::sleep(Duration::from_secs(10));
        println!("Diagnostic stream ended. USB writes completed; visible display output requires user confirmation.");
        return Ok(());
    }
    println!("Two JPEG frames transferred. Check the panel for colour bars, gray ramp and checkerboard.");
    println!("This is an image-output prototype; no macOS virtual desktop has been created.");
    Ok(())
}
