//! The recovery phrase: a 256-bit root key written as 24 checksummed words.
//!
//! It exists for one scenario: a lost device. The app keeps an encrypted
//! backup of a device's state somewhere that is not the device (the user's
//! cloud, or the relay); the backup is useless without this key, and the key
//! lives only on paper. There is no server-side reset: lose the phrase and
//! the backup together and the data is gone, which is the point.
//!
//! The phrase is the standard BIP-39 encoding of 32 random bytes, so the
//! word list is a known, reviewed one and the checksum catches most typos.
//! A different valid phrase still cannot authenticate this key's backup.
//! The encryption key is derived from those bytes with HKDF, so
//! the phrase is never used as a key directly.

use bip39::{Language, Mnemonic};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

const FORMAT_VERSION: u8 = 1;
const NONCE_LEN: usize = 12;
const KEY_INFO: &[u8] = b"cash-app backup encryption key v1";
const AAD: &[u8] = b"cash-app backup v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryError {
    /// The phrase is not 24 valid words with a matching checksum.
    InvalidPhrase,
    /// The bytes are not a backup sealed with this key: wrong key, damaged,
    /// or truncated. Deliberately one error: no hint which.
    CannotOpen,
    /// The operating system could not provide randomness.
    NoRandomness,
}

impl std::fmt::Display for RecoveryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::InvalidPhrase => "that is not a valid 24-word recovery phrase",
            Self::CannotOpen => "this backup cannot be opened with that recovery phrase",
            Self::NoRandomness => "no source of randomness is available",
        })
    }
}

impl std::error::Error for RecoveryError {}

pub struct RecoveryKey {
    entropy: [u8; 32],
}

impl RecoveryKey {
    pub fn generate() -> Self {
        let mut entropy = [0_u8; 32];
        getrandom::getrandom(&mut entropy).expect("the operating system provides randomness");
        Self { entropy }
    }

    /// The 24 words to write down, separated by single spaces.
    pub fn phrase(&self) -> String {
        Mnemonic::from_entropy_in(Language::English, &self.entropy)
            .expect("32 bytes is a valid BIP-39 entropy length")
            .to_string()
    }

    /// Parses a phrase a person typed: case and extra whitespace are
    /// forgiven; invalid word counts/checksums are refused. Some typos can
    /// form another valid phrase; backup authentication rejects that key.
    pub fn from_phrase(phrase: &str) -> Result<Self, RecoveryError> {
        let normalized = phrase
            .split_whitespace()
            .map(str::to_lowercase)
            .collect::<Vec<_>>()
            .join(" ");
        let mnemonic = Mnemonic::parse_in_normalized(Language::English, &normalized)
            .map_err(|_| RecoveryError::InvalidPhrase)?;
        let entropy: [u8; 32] = mnemonic
            .to_entropy()
            .try_into()
            .map_err(|_| RecoveryError::InvalidPhrase)?;
        Ok(Self { entropy })
    }

    fn cipher(&self) -> ChaCha20Poly1305 {
        let mut key = [0_u8; 32];
        Hkdf::<Sha256>::new(None, &self.entropy)
            .expand(KEY_INFO, &mut key)
            .expect("32 bytes is a valid HKDF output length");
        ChaCha20Poly1305::new(Key::from_slice(&key))
    }

    /// Encrypts `plaintext` for storage anywhere: version byte, random
    /// nonce, then ciphertext with its authentication tag.
    pub fn seal(&self, plaintext: &[u8]) -> Result<Vec<u8>, RecoveryError> {
        let mut nonce = [0_u8; NONCE_LEN];
        getrandom::getrandom(&mut nonce).map_err(|_| RecoveryError::NoRandomness)?;
        let ciphertext = self
            .cipher()
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: AAD,
                },
            )
            .map_err(|_| RecoveryError::CannotOpen)?;
        let mut sealed = Vec::with_capacity(1 + NONCE_LEN + ciphertext.len());
        sealed.push(FORMAT_VERSION);
        sealed.extend_from_slice(&nonce);
        sealed.extend_from_slice(&ciphertext);
        Ok(sealed)
    }

    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, RecoveryError> {
        let (version, rest) = sealed.split_first().ok_or(RecoveryError::CannotOpen)?;
        if *version != FORMAT_VERSION || rest.len() < NONCE_LEN {
            return Err(RecoveryError::CannotOpen);
        }
        let (nonce, ciphertext) = rest.split_at(NONCE_LEN);
        self.cipher()
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: AAD,
                },
            )
            .map_err(|_| RecoveryError::CannotOpen)
    }
}
