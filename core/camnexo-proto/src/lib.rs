//! CamNexo wire format: fixed-size little-endian frame header followed by payload.

pub const PROTOCOL_VERSION: u8 = 1;
pub const HEADER_LEN: usize = 28;
/// Upper bound on a single payload; rejects corrupt length fields before allocating.
pub const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PacketType {
    Video = 0,
    Keyframe = 1,
    Control = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Codec {
    H264 = 0,
    H265 = 1,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    TooShort,
    BadVersion(u8),
    BadType(u8),
    BadCodec(u8),
    PayloadTooLarge(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub version: u8,
    pub packet_type: PacketType,
    pub codec: Codec,
    pub flags: u8,
    pub seq: u32,
    pub timestamp_us: u64,
    pub width: u16,
    pub height: u16,
    pub payload_len: u32,
}

impl Header {
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let mut b = [0u8; HEADER_LEN];
        b[0] = self.version;
        b[1] = self.packet_type as u8;
        b[2] = self.codec as u8;
        b[3] = self.flags;
        b[4..8].copy_from_slice(&self.seq.to_le_bytes());
        b[8..16].copy_from_slice(&self.timestamp_us.to_le_bytes());
        b[16..18].copy_from_slice(&self.width.to_le_bytes());
        b[18..20].copy_from_slice(&self.height.to_le_bytes());
        b[20..24].copy_from_slice(&self.payload_len.to_le_bytes());
        // bytes 24..28 reserved for future use, zeroed
        b
    }

    pub fn decode(b: &[u8]) -> Result<Header, DecodeError> {
        if b.len() < HEADER_LEN {
            return Err(DecodeError::TooShort);
        }
        if b[0] != PROTOCOL_VERSION {
            return Err(DecodeError::BadVersion(b[0]));
        }
        let packet_type = match b[1] {
            0 => PacketType::Video,
            1 => PacketType::Keyframe,
            2 => PacketType::Control,
            x => return Err(DecodeError::BadType(x)),
        };
        let codec = match b[2] {
            0 => Codec::H264,
            1 => Codec::H265,
            x => return Err(DecodeError::BadCodec(x)),
        };
        let payload_len = u32::from_le_bytes(b[20..24].try_into().unwrap());
        if payload_len > MAX_PAYLOAD {
            return Err(DecodeError::PayloadTooLarge(payload_len));
        }
        Ok(Header {
            version: b[0],
            packet_type,
            codec,
            flags: b[3],
            seq: u32::from_le_bytes(b[4..8].try_into().unwrap()),
            timestamp_us: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            width: u16::from_le_bytes(b[16..18].try_into().unwrap()),
            height: u16::from_le_bytes(b[18..20].try_into().unwrap()),
            payload_len,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Header {
        Header {
            version: PROTOCOL_VERSION,
            packet_type: PacketType::Keyframe,
            codec: Codec::H264,
            flags: 0,
            seq: 42,
            timestamp_us: 1_234_567_890,
            width: 1920,
            height: 1080,
            payload_len: 65_000,
        }
    }

    #[test]
    fn roundtrip() {
        let h = sample();
        assert_eq!(Header::decode(&h.encode()).unwrap(), h);
    }

    #[test]
    fn rejects_short_buffer() {
        assert_eq!(Header::decode(&[0u8; 10]), Err(DecodeError::TooShort));
    }

    #[test]
    fn rejects_bad_version() {
        let mut b = sample().encode();
        b[0] = 9;
        assert_eq!(Header::decode(&b), Err(DecodeError::BadVersion(9)));
    }

    #[test]
    fn rejects_oversized_payload() {
        let mut h = sample();
        h.payload_len = MAX_PAYLOAD + 1;
        assert_eq!(
            Header::decode(&h.encode()),
            Err(DecodeError::PayloadTooLarge(MAX_PAYLOAD + 1))
        );
    }
}
