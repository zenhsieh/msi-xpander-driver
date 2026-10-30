use anyhow::{ensure, Context, Result};
use rand::{distributions::Alphanumeric, rngs::OsRng, Rng};
use rsa::{pkcs8::DecodePublicKey, traits::PublicKeyParts, BigUint, Pkcs1v15Encrypt, RsaPublicKey};

pub const VID: u16 = 0x0db0;
pub const PID_HID: u16 = 0x7920;
pub const PID_DISPLAY: u16 = 0x7885;
pub const PUBLIC_KEY: &str = include_str!("../assets/vendor-public.pem");

pub fn encode_control(text: &str) -> Result<Vec<u8>> {
    let payload = text.as_bytes();
    ensure!(payload.len() + 5 <= u16::MAX as usize, "Control message is too long");
    let mut inner = Vec::from(((payload.len() + 5) as u16).to_be_bytes());
    inner.extend_from_slice(payload);
    inner.push(inner.iter().fold(0u8, |sum, &b| sum.wrapping_add(b)));
    let mut wire = vec![0x5a];
    for byte in inner {
        match byte { 0x5a => wire.extend_from_slice(&[0x5b, 1]), 0x5b => wire.extend_from_slice(&[0x5b, 2]), _ => wire.push(byte) }
    }
    wire.push(0x5a);
    Ok(wire)
}

pub fn decode_control(wire: &[u8]) -> Result<String> {
    ensure!(wire.first() == Some(&0x5a), "Missing control start delimiter");
    let mut decoded = Vec::new();
    let mut i = 1;
    let mut ended = false;
    while i < wire.len() {
        let b = wire[i]; i += 1;
        if b == 0x5a { ended = true; break; }
        if b == 0x5b {
            ensure!(i < wire.len(), "Incomplete control escape");
            let escape = wire[i]; i += 1;
            ensure!(escape == 1 || escape == 2, "Invalid control escape");
            decoded.push(0x59 + escape);
        } else { decoded.push(b); }
    }
    ensure!(ended && decoded.len() >= 3, "Incomplete control message");
    let length = u16::from_be_bytes([decoded[0], decoded[1]]) as usize;
    ensure!(length == decoded.len() + 2, "Control length mismatch");
    let sum = decoded[..decoded.len()-1].iter().fold(0u8, |sum, &b| sum.wrapping_add(b));
    ensure!(Some(&sum) == decoded.last(), "Control checksum mismatch");
    String::from_utf8(decoded[2..decoded.len()-1].to_vec()).context("Control payload is not UTF-8")
}

pub fn hid_report(text: &str) -> Result<Vec<u8>> {
    let wire = encode_control(text)?;
    ensure!(wire.len() <= 1024, "Control message exceeds one HID report");
    let mut report = vec![0u8; 1025]; // Unnumbered report: leading zero is HIDAPI's report ID.
    report[1..1+wire.len()].copy_from_slice(&wire);
    Ok(report)
}

pub fn packet_header(kind: u8, bytes: u32, sequence: u32) -> [u8; 20] {
    let magic = [kind, 0x2b, 0xc6, 0xa1];
    let mut out = [0u8; 20];
    out[..4].copy_from_slice(&magic);
    out[4..8].copy_from_slice(&bytes.to_le_bytes());
    out[8..12].copy_from_slice(&sequence.to_le_bytes());
    out[16..].copy_from_slice(&magic);
    out
}

pub fn public_key() -> Result<RsaPublicKey> {
    RsaPublicKey::from_public_key_pem(PUBLIC_KEY).context("Invalid bundled vendor public key")
}

// Raw PKCS#1 v1.5 type-1 recovery. The device signs raw challenge bytes, not a hash.
pub fn recover_device_proof(key: &RsaPublicKey, signature: &[u8]) -> Result<Vec<u8>> {
    ensure!(signature.len() == key.size(), "Unexpected RSA response size");
    let value = BigUint::from_bytes_be(signature);
    ensure!(&value < key.n(), "RSA response is outside modulus");
    let raw = value.modpow(key.e(), key.n()).to_bytes_be();
    ensure!(raw.len() <= key.size(), "RSA result too long");
    let mut encoded = vec![0u8; key.size()];
    let start = encoded.len() - raw.len();
    encoded[start..].copy_from_slice(&raw);
    ensure!(encoded.starts_with(&[0, 1]), "Device proof has invalid PKCS#1 type");
    let mut separator = 2;
    while separator < encoded.len() && encoded[separator] == 0xff { separator += 1; }
    ensure!(separator >= 10 && separator < encoded.len() && encoded[separator] == 0, "Device proof padding is invalid");
    ensure!(separator + 1 < encoded.len(), "Device proof is empty");
    Ok(encoded[separator+1..].to_vec())
}

pub trait Transport {
    fn control_read(&mut self, request_type: u8, request: u8, value: u16, index: u16, data: &mut [u8]) -> Result<usize>;
    fn control_write(&mut self, request_type: u8, request: u8, value: u16, index: u16, data: &[u8]) -> Result<usize>;
    fn bulk_out(&mut self, data: &[u8]) -> Result<usize>;
    fn bulk_in(&mut self, data: &mut [u8]) -> Result<usize>;
}

fn write_all<T: Transport>(io: &mut T, data: &[u8]) -> Result<()> {
    let written = io.bulk_out(data)?;
    ensure!(written == data.len(), "Short USB write: {written}/{}", data.len());
    Ok(())
}

pub fn authenticate<T: Transport>(io: &mut T, log: &mut impl FnMut(&str)) -> Result<()> {
    let challenge: Vec<u8> = OsRng.sample_iter(&Alphanumeric).take(124).collect();
    authenticate_with_key(io, &public_key()?, &challenge, log)
}

pub fn authenticate_with_key<T: Transport>(io: &mut T, key: &RsaPublicKey, challenge: &[u8], log: &mut impl FnMut(&str)) -> Result<()> {
    ensure!(key.size() == 256, "Expected the observed 2048-bit RSA protocol");
    ensure!(!challenge.is_empty() && challenge.len() <= 245, "RSA challenge length is invalid");
    let mut params = [0u8; 160];
    let read = io.control_read(0xc0, 0, 0, 0, &mut params).context("Read display parameters")?;
    ensure!(read == 160, "Unexpected display parameter length: {read}");
    let width = u16::from_le_bytes([params[10], params[11]]);
    let height = u16::from_le_bytes([params[12], params[13]]);
    ensure!((width, height) == (1920, 720), "Unexpected device dimensions: {width}x{height}");
    ensure!(io.control_write(0x40, 3, 0, 0, &[])? == 0, "Unexpected control-write result");
    ensure!(io.control_write(0x40, 5, 4, 0, &[])? == 0, "Unexpected encode-type result");
    log("Display parameters validated; starting host challenge");
    let encrypted = key.encrypt(&mut OsRng, Pkcs1v15Encrypt, challenge).context("Encrypt host challenge")?;
    write_all(io, &packet_header(0x10, encrypted.len() as u32, 0))?;
    write_all(io, &encrypted)?;
    let mut reply = [0u8; 256];
    let len = io.bulk_in(&mut reply).context("Read host-challenge echo")?;
    ensure!(len == challenge.len() && &reply[..len] == challenge, "Host-challenge echo did not match; stopping before image transfer");
    log("Host challenge accepted; requesting device proof");
    write_all(io, &packet_header(0x11, 256, 0))?;
    let len = io.bulk_in(&mut reply).context("Read device proof")?;
    ensure!(len == 256, "Short device proof: {len}/256");
    let answer = recover_device_proof(key, &reply)?;
    write_all(io, &answer)?;
    log("Device proof validated and answered");
    Ok(())
}

pub fn send_jpeg<T: Transport>(io: &mut T, jpeg: &[u8], sequence: u32) -> Result<()> {
    ensure!(jpeg.len() > 4 && jpeg.starts_with(&[0xff, 0xd8, 0xff]) && jpeg.ends_with(&[0xff, 0xd9]), "Incomplete JPEG");
    ensure!(jpeg.len() <= 16 * 1024 * 1024, "JPEG is too large");
    write_all(io, &packet_header(1, jpeg.len() as u32, sequence))?;
    write_all(io, jpeg)
}

fn from_hex(text: &str) -> Result<Vec<u8>> {
    ensure!(text.len() % 2 == 0, "Odd hex string length");
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i+2], 16).map_err(Into::into)).collect()
}

pub fn verify_fixtures() -> Result<usize> {
    let fixtures: serde_json::Value = serde_json::from_str(include_str!("../fixtures/commands.json"))?;
    let fixtures = fixtures.as_array().context("Expected fixture array")?;
    for fixture in fixtures {
        let text = fixture["text"].as_str().context("Missing fixture text")?;
        let wire = from_hex(fixture["wireHex"].as_str().context("Missing fixture bytes")?)?;
        ensure!(encode_control(text)? == wire, "Captured command encoding mismatch");
        ensure!(decode_control(&wire)? == text, "Captured command decoding mismatch");
    }
    let proof = recover_device_proof(&public_key()?, include_bytes!("../fixtures/device-proof.bin"))?;
    ensure!(proof.as_slice() == include_bytes!("../fixtures/expected-proof.bin").as_slice(), "Captured RSA proof mismatch");
    let header = include_bytes!("../fixtures/jpeg-header.bin");
    ensure!(packet_header(1, 22226, 0x100000) == *header, "Captured JPEG header mismatch");
    Ok(fixtures.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn captured_protocol_and_rsa_proof_match() { assert_eq!(verify_fixtures().unwrap(), 10); }
    #[test] fn escaped_delimiters_round_trip() {
        for text in ["Z[", "POST demo 1\r\n\r\n{\"value\":\"Z[\"}"] {
            assert_eq!(decode_control(&encode_control(text).unwrap()).unwrap(), text);
        }
    }
    #[test] fn invalid_checksum_is_rejected() {
        let mut wire = encode_control("abc").unwrap(); wire[3] ^= 1;
        assert!(decode_control(&wire).is_err());
    }
    #[test] fn invalid_padding_is_rejected() {
        let mut proof = include_bytes!("../fixtures/device-proof.bin").to_vec(); proof[0] ^= 1;
        assert!(recover_device_proof(&public_key().unwrap(), &proof).is_err());
    }
    #[test] fn short_header_is_rejected() { assert!(decode_control(&[0x5a, 0x5a]).is_err()); }
    #[test] fn incomplete_escape_is_rejected() { assert!(decode_control(&[0x5a, 0x5b]).is_err()); }
    #[test] fn incomplete_jpeg_is_rejected_before_usb() {
        struct Never;
        impl Transport for Never {
            fn control_read(&mut self, _:u8, _:u8, _:u16, _:u16, _:&mut[u8])->Result<usize>{panic!("Unexpected USB")}
            fn control_write(&mut self, _:u8, _:u8, _:u16, _:u16, _:&[u8])->Result<usize>{panic!("Unexpected USB")}
            fn bulk_out(&mut self, _:&[u8])->Result<usize>{panic!("Unexpected USB")}
            fn bulk_in(&mut self, _:&mut[u8])->Result<usize>{panic!("Unexpected USB")}
        }
        assert!(send_jpeg(&mut Never, &[0xff, 0xd8, 0xff], 1).is_err());
    }
}


/// Frame the Dashboard image transport observed in capture 125.
/// Reports contain 1000 JPEG bytes at most; the 21-byte application header
/// follows the 5c marker and two-byte big-endian body length.
pub fn dashboard_image_reports(jpeg: &[u8]) -> Result<Vec<Vec<u8>>> {
    ensure!(jpeg.starts_with(&[0xff,0xd8,0xff]) && jpeg.ends_with(&[0xff,0xd9]), "Incomplete Dashboard JPEG");
    let total = jpeg.len().div_ceil(1000);
    ensure!(total > 0 && total <= u16::MAX as usize, "Too many Dashboard image chunks");
    let mut reports = Vec::with_capacity(total);
    for (index, chunk) in jpeg.chunks(1000).enumerate() {
        let mut report = vec![0u8;1025];
        report[1] = 0x5c;
        report[2..4].copy_from_slice(&((chunk.len()+21) as u16).to_be_bytes());
        report[5..7].copy_from_slice(&(total as u16).to_be_bytes());
        report[7..9].copy_from_slice(&(index as u16).to_be_bytes());
        report[25..25+chunk.len()].copy_from_slice(chunk);
        reports.push(report);
    }
    Ok(reports)
}

#[derive(Debug, PartialEq, Eq)]
pub struct JpegProfile {
    pub width: u16,
    pub height: u16,
    pub sampling: Vec<u8>,
}

pub fn jpeg_profile(jpeg: &[u8]) -> Result<JpegProfile> {
    ensure!(jpeg.starts_with(&[0xff,0xd8]), "Missing JPEG start marker");
    let mut pos = 2;
    while pos + 4 <= jpeg.len() {
        ensure!(jpeg[pos] == 0xff, "Invalid JPEG marker at {pos}");
        while pos < jpeg.len() && jpeg[pos] == 0xff { pos += 1; }
        ensure!(pos < jpeg.len(), "Incomplete JPEG marker");
        let marker = jpeg[pos]; pos += 1;
        ensure!(marker != 0xda && marker != 0xd9, "No baseline JPEG frame header");
        ensure!(pos + 2 <= jpeg.len(), "Incomplete JPEG segment length");
        let length = u16::from_be_bytes([jpeg[pos],jpeg[pos+1]]) as usize;
        ensure!(length >= 2 && pos + length <= jpeg.len(), "Invalid JPEG segment length");
        let data = &jpeg[pos+2..pos+length];
        if marker == 0xc0 {
            ensure!(data.len() >= 6 && data[0] == 8, "Unsupported JPEG precision");
            let components = data[5] as usize;
            ensure!(components == 3 && data.len() == 6+3*components, "Expected three JPEG components");
            return Ok(JpegProfile {
                height:u16::from_be_bytes([data[1],data[2]]),
                width:u16::from_be_bytes([data[3],data[4]]),
                sampling:(0..components).map(|i|data[7+i*3]).collect(),
            });
        }
        ensure!(marker != 0xc2, "Progressive JPEG is outside the observed panel format");
        pos += length;
    }
    anyhow::bail!("Incomplete JPEG frame header")
}

#[cfg(test)]
mod display_compatibility_tests {
    use super::*;
    #[test]
    fn dashboard_reports_match_all_51_captured_reports() {
        let reports=dashboard_image_reports(include_bytes!("../assets/dashboard-prime.jpg")).unwrap();
        let expected=include_bytes!("../fixtures/dashboard-reports.bin");
        assert_eq!(reports.len(),51);
        assert_eq!(expected.len(),51*1024);
        for (i,report) in reports.iter().enumerate() {
            let recorded=&expected[i*1024..(i+1)*1024];
            let meaningful=3+u16::from_be_bytes([recorded[1],recorded[2]])as usize;
            assert_eq!(report[0],0);
            assert_eq!(&report[1..1+meaningful],&recorded[..meaningful]);
        }
    }
    #[test]
    fn official_extended_frame_is_baseline_420() {
        let mut jpeg=vec![0xff,0xd8];
        jpeg.extend_from_slice(include_bytes!("../fixtures/official-jpeg-sof0.bin"));
        jpeg.extend_from_slice(&[0xff,0xd9]);
        let p=jpeg_profile(&jpeg).unwrap();
        assert_eq!((p.width,p.height),(1920,720));
        assert_eq!(p.sampling,vec![0x22,0x11,0x11]);
    }
    #[test]
    fn dashboard_profile_is_baseline_420() {
        let p=jpeg_profile(include_bytes!("../assets/dashboard-prime.jpg")).unwrap();
        assert_eq!((p.width,p.height),(1440,540));
        assert_eq!(p.sampling,vec![0x22,0x11,0x11]);
    }
    #[test]
    fn malformed_jpeg_is_rejected() {
        assert!(jpeg_profile(&[0xff,0xd8,0xff,0xc0,0xff,0xff]).is_err());
        assert!(dashboard_image_reports(&[0xff,0xd8]).is_err());
    }
}
