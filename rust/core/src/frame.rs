//! Generic durable-log framing, shared by every append-only byte log this
//! crate defines (the financial event log in `codec.rs`, the category
//! last-writer-wins log in `categories.rs`, and any future one).
//!
//! A frame is a version byte, a length-prefixed payload, and a checksum of
//! that payload. Framing says nothing about what the payload means: each log
//! supplies its own payload encoder/decoder and gets the same crash-recovery
//! guarantee for free. A torn write (the process dies mid-`flush`) can only
//! ever corrupt the last, still-in-flight frame, so decoding stops at the
//! first frame that fails its checksum or runs out of bytes and reports how
//! many trailing bytes were unreadable, instead of discarding everything
//! decoded so far or panicking.

use crate::bytes_io::{Reader, write_u32};

/// Frame format version. Existing frames must keep decoding under this
/// version forever: a durable log is the only copy of a user's history.
const FRAME_FORMAT_VERSION: u8 = 1;

/// The result of decoding a durable log's bytes back into items.
pub struct DecodedFrameLog<T> {
    pub items: Vec<T>,
    /// Bytes at the tail of the log that were not a complete, checksum-valid
    /// frame. Expected after a crash mid-write; the safe recovery is to keep
    /// every item decoded before this point and drop only this remainder.
    pub trailing_garbage_bytes: usize,
}

/// Wraps one payload as a self-contained, checksummed frame ready to append
/// to a durable log. The same payload always encodes to the same bytes.
pub fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(payload.len() + 9);
    frame.push(FRAME_FORMAT_VERSION);
    write_u32(&mut frame, payload.len() as u32);
    frame.extend_from_slice(payload);
    write_u32(&mut frame, fnv1a32(payload));
    frame
}

/// Decodes a byte buffer made of zero or more frames written by
/// [`encode_frame`], back-to-back, in append order. `decode_payload` turns a
/// checksum-verified payload into an item; if it returns `None` (a payload
/// that doesn't parse despite a valid checksum, e.g. a newer, unrecognized
/// format), decoding stops there just as it would for a torn write.
pub fn decode_frame_log<T>(
    bytes: &[u8],
    decode_payload: impl Fn(&[u8]) -> Option<T>,
) -> DecodedFrameLog<T> {
    let mut items = Vec::new();
    let mut reader = Reader::new(bytes);
    loop {
        if reader.remaining() == 0 {
            return DecodedFrameLog {
                items,
                trailing_garbage_bytes: 0,
            };
        }
        let start = reader.offset();
        match decode_frame(&mut reader, &decode_payload) {
            Some(item) => items.push(item),
            None => {
                return DecodedFrameLog {
                    items,
                    trailing_garbage_bytes: bytes.len() - start,
                };
            }
        }
    }
}

fn decode_frame<T>(
    reader: &mut Reader<'_>,
    decode_payload: impl Fn(&[u8]) -> Option<T>,
) -> Option<T> {
    if reader.read_u8()? != FRAME_FORMAT_VERSION {
        return None;
    }
    let length = usize::try_from(reader.read_u32()?).ok()?;
    let payload = reader.read_bytes(length)?;
    let checksum = reader.read_u32()?;
    if fnv1a32(payload) != checksum {
        return None;
    }
    decode_payload(payload)
}

fn fnv1a32(data: &[u8]) -> u32 {
    const OFFSET_BASIS: u32 = 0x811c_9dc5;
    const PRIME: u32 = 0x0100_0193;
    let mut hash = OFFSET_BASIS;
    for &byte in data {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_payload_round_trips_through_a_frame() {
        let payload = b"hello frame".to_vec();
        let frame = encode_frame(&payload);
        let decoded = decode_frame_log(&frame, |bytes| Some(bytes.to_vec()));
        assert_eq!(decoded.trailing_garbage_bytes, 0);
        assert_eq!(decoded.items, vec![payload]);
    }

    #[test]
    fn a_checksum_failure_stops_decoding_and_reports_the_remainder() {
        let mut frame = encode_frame(b"payload");
        let flip_at = frame.len() - 1;
        frame[flip_at] ^= 0xFF;

        let decoded = decode_frame_log(&frame, |bytes| Some(bytes.to_vec()));
        assert!(decoded.items.is_empty());
        assert_eq!(decoded.trailing_garbage_bytes, frame.len());
    }
}
