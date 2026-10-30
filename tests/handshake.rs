use anyhow::{ensure, Result};
use msi_xpander::{authenticate_with_key, packet_header, public_key, Transport};

struct MockUsb {
    writes: Vec<Vec<u8>>,
    challenge: Vec<u8>,
    reads: usize,
    wrong_echo: bool,
    short_write: bool,
}
impl MockUsb {
    fn new() -> Self { Self { writes: Vec::new(), challenge: vec![b'A';124], reads: 0, wrong_echo: false, short_write: false } }
}
impl Transport for MockUsb {
    fn control_read(&mut self, rt:u8, r:u8, v:u16, i:u16, data:&mut[u8]) -> Result<usize> {
        ensure!((rt,r,v,i,data.len()) == (0xc0,0,0,0,160));
        data[10..12].copy_from_slice(&1920u16.to_le_bytes());
        data[12..14].copy_from_slice(&720u16.to_le_bytes());
        Ok(160)
    }
    fn control_write(&mut self, rt:u8, r:u8, v:u16, i:u16, data:&[u8]) -> Result<usize> {
        ensure!(rt == 0x40 && i == 0 && data.is_empty());
        ensure!((r,v) == (3,0) || (r,v) == (5,4));
        Ok(0)
    }
    fn bulk_out(&mut self, data:&[u8]) -> Result<usize> {
        self.writes.push(data.to_vec());
        Ok(if self.short_write { data.len().saturating_sub(1) } else { data.len() })
    }
    fn bulk_in(&mut self, data:&mut[u8]) -> Result<usize> {
        self.reads += 1;
        let reply = if self.reads == 1 {
            if self.wrong_echo { vec![b'B';124] } else { self.challenge.clone() }
        } else { include_bytes!("../fixtures/device-proof.bin").to_vec() };
        data[..reply.len()].copy_from_slice(&reply);
        Ok(reply.len())
    }
}

#[test]
fn complete_handshake_reproduces_recorded_order() {
    let mut usb = MockUsb::new();
    let challenge = usb.challenge.clone();
    authenticate_with_key(&mut usb, &public_key().unwrap(), &challenge, &mut |_| {}).unwrap();
    assert_eq!(usb.writes.len(), 4);
    assert_eq!(usb.writes[0], packet_header(0x10,256,0));
    assert_eq!(usb.writes[1].len(), 256);
    assert_ne!(usb.writes[1], challenge);
    assert_eq!(usb.writes[2], packet_header(0x11,256,0));
    assert_eq!(usb.writes[3].as_slice(), include_bytes!("../fixtures/expected-proof.bin").as_slice());
}

#[test]
fn bad_echo_stops_before_device_proof_and_jpeg() {
    let mut usb = MockUsb::new(); usb.wrong_echo = true;
    let challenge = usb.challenge.clone();
    assert!(authenticate_with_key(&mut usb, &public_key().unwrap(), &challenge, &mut |_| {}).is_err());
    assert_eq!(usb.writes.len(), 2);
    assert_eq!(usb.reads, 1);
}

#[test]
fn short_write_stops_immediately() {
    let mut usb = MockUsb::new(); usb.short_write = true;
    let challenge = usb.challenge.clone();
    assert!(authenticate_with_key(&mut usb, &public_key().unwrap(), &challenge, &mut |_| {}).is_err());
    assert_eq!(usb.writes.len(), 1);
    assert_eq!(usb.reads, 0);
}
