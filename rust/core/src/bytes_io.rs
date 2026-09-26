//! Small binary primitives shared by canonical state serialization
//! (`LedgerState::canonical_bytes`) and the durable event log codec. Every
//! writer is paired with a reader that fails safely (returns `None`) on
//! truncated or otherwise malformed input instead of panicking, because both
//! callers must tolerate corrupted bytes from a torn write.

pub(crate) fn write_bool(bytes: &mut Vec<u8>, value: bool) {
    bytes.push(u8::from(value));
}

pub(crate) fn write_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

pub(crate) fn write_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

pub(crate) fn write_i64(bytes: &mut Vec<u8>, value: i64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

pub(crate) fn write_string(bytes: &mut Vec<u8>, value: &str) {
    write_u64(bytes, value.len() as u64);
    bytes.extend_from_slice(value.as_bytes());
}

pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    pub(crate) fn offset(&self) -> usize {
        self.offset
    }

    pub(crate) fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }

    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        if self.remaining() < len {
            return None;
        }
        let slice = &self.bytes[self.offset..self.offset + len];
        self.offset += len;
        Some(slice)
    }

    pub(crate) fn read_bool(&mut self) -> Option<bool> {
        match self.take(1)?[0] {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }

    pub(crate) fn read_u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }

    pub(crate) fn read_u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    pub(crate) fn read_u64(&mut self) -> Option<u64> {
        Some(u64::from_be_bytes(self.take(8)?.try_into().ok()?))
    }

    pub(crate) fn read_i64(&mut self) -> Option<i64> {
        Some(i64::from_be_bytes(self.take(8)?.try_into().ok()?))
    }

    pub(crate) fn read_string(&mut self) -> Option<String> {
        let len = usize::try_from(self.read_u64()?).ok()?;
        String::from_utf8(self.take(len)?.to_vec()).ok()
    }

    pub(crate) fn read_bytes(&mut self, len: usize) -> Option<&'a [u8]> {
        self.take(len)
    }
}
