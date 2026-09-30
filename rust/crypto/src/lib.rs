//! MLS group encryption for the household-sharing layer (Phase 2), wrapping
//! OpenMLS so the rest of the app never touches its types. Phase 0 proved
//! this stack on iOS, Android, and web (`docs/PHASE0-RESULT.md`); the pinned
//! versions in `Cargo.toml` are the ones that passed.
//!
//! Everything here is bytes in, bytes out: key packages, commits, welcomes,
//! and application messages are opaque blobs that a relay can carry but not
//! read. Ordering is the caller's job (the relay's totally ordered log);
//! this crate only needs each member to process the stream in that order.

use std::collections::HashSet;
use std::fmt::Debug;

use openmls::prelude::tls_codec::Serialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use sha2::{Digest, Sha256};

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

fn fail(error: impl Debug) -> Error {
    Error(format!("{error:?}"))
}

/// What processing one relay entry did to this member.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Received {
    /// A decrypted application message.
    Application(Vec<u8>),
    /// A commit that moved this member to `epoch`.
    Commit { epoch: u64 },
    /// A commit that removed this member; the group is now inactive here.
    Removed,
    /// This member's own earlier message, echoed back by the relay.
    Own,
}

/// A commit that adds one member, plus the welcome only that member needs.
/// Nothing is applied locally until [`Member::confirm_commit`].
pub struct Invite {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// One person's device: a signing identity and at most one MLS group (the
/// household). Commits this member creates stay pending until the relay
/// accepts them, so a commit that loses the race can be discarded cleanly.
pub struct Member {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    group: Option<MlsGroup>,
    sent: HashSet<[u8; 32]>,
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

impl Member {
    /// `name` is the member's display name inside the group's credential.
    pub fn new(name: &str) -> Result<Self, Error> {
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(fail)?;
        signer.store(provider.storage()).map_err(fail)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(name.as_bytes().to_vec()).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
            group: None,
            sent: HashSet::new(),
        })
    }

    /// The raw public signing key: what a safety number is computed from.
    pub fn public_key(&self) -> Vec<u8> {
        self.signer.public().to_vec()
    }

    /// A fresh single-use key package for someone to add this member with.
    pub fn key_package(&self) -> Result<Vec<u8>, Error> {
        let bundle = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(fail)?;
        bundle.key_package().tls_serialize_detached().map_err(fail)
    }

    pub fn create_group(&mut self) -> Result<(), Error> {
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();
        self.group = Some(
            MlsGroup::new(
                &self.provider,
                &self.signer,
                &config,
                self.credential.clone(),
            )
            .map_err(fail)?,
        );
        Ok(())
    }

    pub fn join(&mut self, welcome: &[u8]) -> Result<(), Error> {
        let message = MlsMessageIn::tls_deserialize_exact_bytes(welcome).map_err(fail)?;
        let MlsMessageBodyIn::Welcome(welcome) = message.extract() else {
            return Err(Error("not a welcome message".to_owned()));
        };
        let config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .build();
        let group = StagedWelcome::new_from_welcome(&self.provider, &config, welcome, None)
            .map_err(fail)?
            .into_group(&self.provider)
            .map_err(fail)?;
        self.group = Some(group);
        Ok(())
    }

    fn group(&self) -> Result<&MlsGroup, Error> {
        self.group
            .as_ref()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))
    }

    pub fn epoch(&self) -> u64 {
        self.group
            .as_ref()
            .map_or(0, |group| group.epoch().as_u64())
    }

    pub fn is_active(&self) -> bool {
        self.group.as_ref().is_some_and(MlsGroup::is_active)
    }

    /// Display names of the current members, in tree order.
    pub fn member_names(&self) -> Result<Vec<String>, Error> {
        Ok(self
            .group()?
            .members()
            .map(|member| {
                let credential = BasicCredential::try_from(member.credential)
                    .map(|basic| String::from_utf8_lossy(basic.identity()).into_owned());
                credential.unwrap_or_default()
            })
            .collect())
    }

    /// Public signing keys of the current members: the inputs for
    /// comparing safety numbers out of band.
    pub fn member_keys(&self) -> Result<Vec<(String, Vec<u8>)>, Error> {
        Ok(self
            .group()?
            .members()
            .map(|member| {
                let name = BasicCredential::try_from(member.credential)
                    .map(|basic| String::from_utf8_lossy(basic.identity()).into_owned())
                    .unwrap_or_default();
                (name, member.signature_key)
            })
            .collect())
    }

    /// Stages a commit adding the holder of `key_package`. The group stays at
    /// its current epoch until [`Self::confirm_commit`].
    pub fn add(&mut self, key_package: &[u8]) -> Result<Invite, Error> {
        let key_package = KeyPackageIn::tls_deserialize_exact_bytes(key_package)
            .map_err(fail)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(fail)?;
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        let (commit, welcome, _) = group
            .add_members(&self.provider, &self.signer, &[key_package])
            .map_err(fail)?;
        Ok(Invite {
            commit: commit.tls_serialize_detached().map_err(fail)?,
            welcome: welcome.tls_serialize_detached().map_err(fail)?,
        })
    }

    /// Stages a commit removing the member named `name`.
    pub fn remove(&mut self, name: &str) -> Result<Vec<u8>, Error> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        let target = group
            .members()
            .find(|member| {
                BasicCredential::try_from(member.credential.clone())
                    .is_ok_and(|basic| basic.identity() == name.as_bytes())
            })
            .map(|member| member.index)
            .ok_or_else(|| Error(format!("no member named {name}")))?;
        let (commit, _, _) = group
            .remove_members(&self.provider, &self.signer, &[target])
            .map_err(fail)?;
        commit.tls_serialize_detached().map_err(fail)
    }

    /// The relay accepted the staged commit: advance to the new epoch.
    pub fn confirm_commit(&mut self) -> Result<(), Error> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        group.merge_pending_commit(&self.provider).map_err(fail)
    }

    /// The relay rejected the staged commit (another commit won the slot):
    /// drop it and stay at the current epoch.
    pub fn discard_commit(&mut self) -> Result<(), Error> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        group
            .clear_pending_commit(self.provider.storage())
            .map_err(fail)
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, Error> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        let bytes = group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(fail)?
            .tls_serialize_detached()
            .map_err(fail)?;
        self.sent.insert(digest(&bytes));
        Ok(bytes)
    }

    /// Processes one entry of the relay's ordered stream. Entries must be
    /// fed in stream order; an entry from an epoch this member has already
    /// left (for instance, after being removed) fails.
    pub fn receive(&mut self, bytes: &[u8]) -> Result<Received, Error> {
        if self.sent.contains(&digest(bytes)) {
            return Ok(Received::Own);
        }
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| Error("this member is not in a group".to_owned()))?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(fail)?;
        let processed = group
            .process_message(
                &self.provider,
                message.try_into_protocol_message().map_err(fail)?,
            )
            .map_err(fail)?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                Ok(Received::Application(message.into_bytes()))
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group
                    .merge_staged_commit(&self.provider, *staged)
                    .map_err(fail)?;
                if group.is_active() {
                    Ok(Received::Commit {
                        epoch: group.epoch().as_u64(),
                    })
                } else {
                    Ok(Received::Removed)
                }
            }
            _ => Err(Error("unsupported MLS message type".to_owned())),
        }
    }
}

/// A Signal-style safety number for two members: six groups of five digits,
/// identical whichever side computes it, so two people can compare it out of
/// band and confirm neither was handed a substituted key.
pub fn safety_number(key_a: &[u8], key_b: &[u8]) -> String {
    let (first, second) = if key_a <= key_b {
        (key_a, key_b)
    } else {
        (key_b, key_a)
    };
    let mut hasher = Sha256::new();
    hasher.update(b"cash-app safety number v1");
    hasher.update((first.len() as u64).to_be_bytes());
    hasher.update(first);
    hasher.update((second.len() as u64).to_be_bytes());
    hasher.update(second);
    let hash = hasher.finalize();
    hash.chunks_exact(5)
        .take(6)
        .map(|chunk| {
            let value = chunk.iter().fold(0_u64, |accumulator, byte| {
                (accumulator << 8) | u64::from(*byte)
            });
            format!("{:05}", value % 100_000)
        })
        .collect::<Vec<_>>()
        .join(" ")
}
