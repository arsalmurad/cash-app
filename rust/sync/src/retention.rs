//! Local receipt codec only. These bytes must travel inside an authenticated
//! encrypted channel; they are not a relay pruning command or a saved archive.
use crate::peer::{Reader, SyncError, write_field};

const MAGIC: &[u8] = b"cash-app durable receipt v2\0";
const MAX_GROUP_BYTES: usize = 256;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Receipt {
    pub group: Vec<u8>,
    pub relay_group: [u8; 32],
    pub epoch: u64,
    pub cursor: u64,
    pub checkpoint: [u8; 32],
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

impl Receipt {
    pub fn payload(&self) -> Vec<u8> {
        let mut bytes = MAGIC.to_vec();
        write_field(&mut bytes, &self.group);
        bytes.extend_from_slice(&self.relay_group);
        bytes.extend_from_slice(&self.epoch.to_be_bytes());
        bytes.extend_from_slice(&self.cursor.to_be_bytes());
        bytes.extend_from_slice(&self.checkpoint);
        bytes.extend_from_slice(&self.public_key);
        bytes
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = self.payload();
        bytes.extend_from_slice(&self.signature);
        bytes
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, SyncError> {
        let malformed = || SyncError("invalid saved-state receipt".to_owned());
        // Bound parsing before inspecting any attacker-controlled field length.
        if bytes.len() > MAGIC.len() + 8 + MAX_GROUP_BYTES + 32 + 16 + 32 + 32 + 64 {
            return Err(malformed());
        }
        let mut reader = Reader { bytes };
        if reader.take(MAGIC.len()) != Some(MAGIC) {
            return Err(malformed());
        }
        let group = reader.field().ok_or_else(malformed)?;
        if group.is_empty() || group.len() > MAX_GROUP_BYTES {
            return Err(malformed());
        }
        let relay_group: [u8; 32] = reader.take(32).ok_or_else(malformed)?.try_into().unwrap();
        if !relay_group
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
        {
            return Err(malformed());
        }
        let epoch = u64::from_be_bytes(reader.take(8).ok_or_else(malformed)?.try_into().unwrap());
        let cursor = u64::from_be_bytes(reader.take(8).ok_or_else(malformed)?.try_into().unwrap());
        let checkpoint = reader.take(32).ok_or_else(malformed)?.try_into().unwrap();
        let public_key = reader.take(32).ok_or_else(malformed)?.to_vec();
        let signature = reader.take(64).ok_or_else(malformed)?.to_vec();
        if !reader.bytes.is_empty() {
            return Err(malformed());
        }
        Ok(Self {
            group: group.to_vec(),
            relay_group,
            epoch,
            cursor,
            checkpoint,
            public_key,
            signature,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_codec_rejects_every_truncation_overflow_and_trailing_byte() {
        let receipt = Receipt {
            group: vec![7; 32],
            relay_group: [b'0'; 32],
            epoch: 4,
            cursor: 99,
            checkpoint: [8; 32],
            public_key: vec![9; 32],
            signature: vec![10; 64],
        };
        let bytes = receipt.encode();
        assert!(Receipt::decode(&bytes).unwrap() == receipt);
        for end in 0..bytes.len() {
            assert!(Receipt::decode(&bytes[..end]).is_err());
        }
        let mut overflowing = bytes.clone();
        overflowing[MAGIC.len()..MAGIC.len() + 8].fill(0xff);
        assert!(Receipt::decode(&overflowing).is_err());
        let mut trailing = bytes;
        trailing.push(0);
        assert!(Receipt::decode(&trailing).is_err());
        assert!(Receipt::decode(&vec![0; 1024 * 1024]).is_err());
        let mut old_version = receipt.encode();
        let old_magic = b"cash-app durable receipt v1\0";
        old_version[..old_magic.len()].copy_from_slice(old_magic);
        assert!(Receipt::decode(&old_version).is_err());
    }
}
