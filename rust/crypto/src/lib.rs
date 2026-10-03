//! MLS group encryption for the household-sharing layer (Phase 2), wrapping
//! OpenMLS so the rest of the app never touches its types. Phase 0 proved
//! this stack on iOS, Android, and web (`docs/PHASE0-RESULT.md`); the pinned
//! versions in `Cargo.toml` are the ones that passed.
//!
//! Everything here is bytes in, bytes out: key packages, commits, welcomes,
//! and application messages are opaque blobs that a relay can carry but not
//! read. Ordering is the caller's job (the relay's totally ordered log);
//! this crate only needs each member to process the stream in that order.

mod recovery;
#[cfg(feature = "relay-auth")]
mod relay_request;

pub use recovery::{RecoveryError, RecoveryKey};
#[cfg(feature = "relay-auth")]
pub use relay_request::RelayRequest;

use std::collections::HashSet;
use std::fmt::Debug;

use openmls::prelude::tls_codec::Serialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{crypto::OpenMlsCrypto, signatures::Signer};
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

/// The identity OpenMLS authenticated, never an application-provided actor ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedSender {
    pub identity: String,
    pub public_key: Vec<u8>,
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

const EXPORT_MAGIC: &[u8] = b"cash-app member v1\0";

fn write_field(bytes: &mut Vec<u8>, field: &[u8]) {
    bytes.extend_from_slice(&(field.len() as u64).to_be_bytes());
    bytes.extend_from_slice(field);
}

struct ExportReader<'a> {
    bytes: &'a [u8],
}

impl<'a> ExportReader<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        if self.bytes.len() < len {
            return None;
        }
        let (head, tail) = self.bytes.split_at(len);
        self.bytes = tail;
        Some(head)
    }

    fn field(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(u64::from_be_bytes(self.take(8)?.try_into().ok()?)).ok()?;
        self.take(len)
    }
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// Self-certifying event-author identity. A caller-chosen member label must
/// never let one signing key impersonate another event author.
pub fn author_id(public_key: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"cash-app author identity v1\0");
    hasher.update(public_key);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
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

    /// Everything needed to resume as this member after the app restarts:
    /// identity, group state, and the record of messages it sent. The bytes
    /// contain private keys; the caller must store them as it would a
    /// password (the platform keychain or an encrypted file).
    pub fn export(&self) -> Result<Vec<u8>, Error> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(EXPORT_MAGIC);
        let name = match BasicCredential::try_from(self.credential.credential.clone()) {
            Ok(basic) => basic.identity().to_vec(),
            Err(error) => return Err(fail(error)),
        };
        write_field(&mut bytes, &name);
        write_field(&mut bytes, self.signer.public());
        match &self.group {
            Some(group) => {
                bytes.push(1);
                write_field(&mut bytes, group.group_id().as_slice());
            }
            None => bytes.push(0),
        }
        let mut storage = Vec::new();
        {
            let values = self
                .provider
                .storage()
                .values
                .read()
                .map_err(|_| Error("poisoned storage".to_owned()))?;
            let mut entries: Vec<_> = values.iter().collect();
            entries.sort();
            storage.extend_from_slice(&(entries.len() as u64).to_be_bytes());
            for (key, value) in entries {
                write_field(&mut storage, key);
                write_field(&mut storage, value);
            }
        }
        write_field(&mut bytes, &storage);
        bytes.extend_from_slice(&(self.sent.len() as u64).to_be_bytes());
        let mut sent: Vec<_> = self.sent.iter().collect();
        sent.sort();
        for digest in sent {
            bytes.extend_from_slice(digest);
        }
        Ok(bytes)
    }

    /// Restores a member from [`Self::export`]'s output.
    pub fn import(bytes: &[u8]) -> Result<Self, Error> {
        let malformed = || Error("malformed member state".to_owned());
        let mut reader = ExportReader { bytes };
        if reader.take(EXPORT_MAGIC.len()) != Some(EXPORT_MAGIC) {
            return Err(malformed());
        }
        let name = reader.field().ok_or_else(malformed)?.to_vec();
        let public_key = reader.field().ok_or_else(malformed)?.to_vec();
        let group_id = match reader.take(1).ok_or_else(malformed)?[0] {
            0 => None,
            1 => Some(reader.field().ok_or_else(malformed)?.to_vec()),
            _ => return Err(malformed()),
        };
        let storage_bytes = reader.field().ok_or_else(malformed)?;
        let count = usize::try_from(u64::from_be_bytes(
            reader
                .take(8)
                .ok_or_else(malformed)?
                .try_into()
                .map_err(|_| malformed())?,
        ))
        .map_err(|_| malformed())?;
        let mut sent = HashSet::new();
        for _ in 0..count {
            let digest: [u8; 32] = reader
                .take(32)
                .ok_or_else(malformed)?
                .try_into()
                .map_err(|_| malformed())?;
            sent.insert(digest);
        }
        if !reader.bytes.is_empty() {
            return Err(malformed());
        }

        let mut storage = ExportReader {
            bytes: storage_bytes,
        };
        let entries = usize::try_from(u64::from_be_bytes(
            storage
                .take(8)
                .ok_or_else(malformed)?
                .try_into()
                .map_err(|_| malformed())?,
        ))
        .map_err(|_| malformed())?;
        let mut values = std::collections::HashMap::new();
        for _ in 0..entries {
            let key = storage.field().ok_or_else(malformed)?.to_vec();
            let value = storage.field().ok_or_else(malformed)?.to_vec();
            values.insert(key, value);
        }
        if !storage.bytes.is_empty() {
            return Err(malformed());
        }

        let provider = OpenMlsRustCrypto::default();
        *provider
            .storage()
            .values
            .write()
            .map_err(|_| Error("poisoned storage".to_owned()))? = values;

        let signer = SignatureKeyPair::read(
            provider.storage(),
            &public_key,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or_else(|| Error("the signing key is missing from the saved state".to_owned()))?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(name).into(),
            signature_key: signer.public().into(),
        };
        let group = match group_id {
            Some(id) => Some(
                MlsGroup::load(provider.storage(), &GroupId::from_slice(&id))
                    .map_err(fail)?
                    .ok_or_else(|| Error("the group is missing from the saved state".to_owned()))?,
            ),
            None => None,
        };
        Ok(Self {
            provider,
            signer,
            credential,
            group,
            sent,
        })
    }

    /// The raw public signing key: what a safety number is computed from.
    pub fn public_key(&self) -> Vec<u8> {
        self.signer.public().to_vec()
    }

    /// Public cryptographic group binding, not an epoch secret or relay ID.
    pub fn group_identifier(&self) -> Option<Vec<u8>> {
        self.group
            .as_ref()
            .map(|group| group.group_id().as_slice().to_vec())
    }

    fn history_payload(&self, payload: &[u8]) -> Result<Vec<u8>, Error> {
        let mut bytes = b"cash-app authenticated history v1\0".to_vec();
        write_field(&mut bytes, self.group()?.group_id().as_slice());
        write_field(&mut bytes, payload);
        Ok(bytes)
    }

    /// Sign immutable history with the existing MLS Ed25519 identity. Domain
    /// separation and the cryptographic group ID prevent cross-protocol and
    /// cross-household replay. This signature survives forwarding and removal.
    pub fn sign_history(&self, payload: &[u8]) -> Result<Vec<u8>, Error> {
        if !self.is_active() {
            return Err(Error(
                "only an active member can sign new history".to_owned(),
            ));
        }
        self.signer
            .sign(&self.history_payload(payload)?)
            .map_err(fail)
    }

    /// Verify an original author's proof, including after that author leaves.
    /// Authorization and binding this key to an actor remain the sync layer's
    /// responsibility; a valid signature alone does not establish membership.
    pub fn verify_history(
        &self,
        public_key: &[u8],
        payload: &[u8],
        signature: &[u8],
    ) -> Result<(), Error> {
        self.provider
            .crypto()
            .verify_signature(
                CIPHERSUITE.signature_algorithm(),
                &self.history_payload(payload)?,
                public_key,
                signature,
            )
            .map_err(fail)
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
        // Pinned explicitly, though it is also OpenMLS's default: commits
        // carry credentials, so they must be encrypted like application
        // messages, or the relay could read member identities out of an Add.
        // `rust/sync/tests/three_peers.rs` fails if this ever becomes
        // plaintext (checked by switching the policy to plaintext).
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
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
            .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
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

    /// Sorted public signing keys for relay authorization. A pending projection
    /// uses OpenMLS's staged public tree without merging the actual commit or
    /// exporting private state. Names and encryption keys are not returned.
    pub fn relay_roster_keys(&self, pending: bool) -> Result<Vec<Vec<u8>>, Error> {
        let group = self.group()?;
        if !group.is_active() {
            return Err(Error(
                "inactive member cannot project relay permissions".to_owned(),
            ));
        }
        let tree = if pending {
            group
                .pending_commit()
                .ok_or_else(|| Error("no pending membership commit".to_owned()))?
                .export_ratchet_tree(self.provider.crypto(), group.export_ratchet_tree())
                .map_err(fail)?
                .ok_or_else(|| Error("pending membership has no member tree".to_owned()))?
        } else {
            group.export_ratchet_tree()
        };
        let mut keys = Vec::new();
        for node in tree.nodes() {
            if let Node::LeafNode(leaf) = node {
                let key = leaf.signature_key().as_slice();
                if key.len() != 32 || keys.len() >= 64 {
                    return Err(Error(
                        "relay roster exceeds supported signing-key bounds".to_owned(),
                    ));
                }
                keys.push(key.to_vec());
            }
        }
        keys.sort();
        if keys.is_empty() || keys.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(Error(
                "relay roster contains missing or duplicate keys".to_owned(),
            ));
        }
        Ok(keys)
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
        let identity = BasicCredential::try_from(key_package.leaf_node().credential().clone())
            .map_err(fail)?;
        if group.members().any(|member| {
            BasicCredential::try_from(member.credential)
                .is_ok_and(|existing| existing.identity() == identity.identity())
        }) {
            return Err(Error(
                "a member with this identity already belongs to the household".to_owned(),
            ));
        }
        let (commit, welcome, _) = group
            .add_members(&self.provider, &self.signer, &[key_package])
            .map_err(fail)?;
        let commit = commit.tls_serialize_detached().map_err(fail)?;
        self.sent.insert(digest(&commit));
        Ok(Invite {
            commit,
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
        let commit = commit.tls_serialize_detached().map_err(fail)?;
        self.sent.insert(digest(&commit));
        Ok(commit)
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
        self.receive_authenticated(bytes)
            .map(|(received, _)| received)
    }

    /// Process a stream entry and retain the MLS-authenticated application
    /// sender. Commits and own-message echoes have no application sender.
    pub fn receive_authenticated(
        &mut self,
        bytes: &[u8],
    ) -> Result<(Received, Option<AuthenticatedSender>), Error> {
        if self.sent.contains(&digest(bytes)) {
            return Ok((Received::Own, None));
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
        let sender = if matches!(
            processed.content(),
            ProcessedMessageContent::ApplicationMessage(_)
        ) {
            // The transport feeds the totally ordered stream. Do not resolve a
            // past epoch's leaf index against the current epoch's ratchet tree.
            if processed.epoch() != group.epoch() {
                return Err(Error(
                    "application message is not in the current epoch".to_owned(),
                ));
            }
            let Sender::Member(index) = processed.sender() else {
                return Err(Error("application sender is not a group member".to_owned()));
            };
            let member = group
                .members()
                .find(|member| member.index == *index)
                .ok_or_else(|| {
                    Error("authenticated sender is missing from the group".to_owned())
                })?;
            if &member.credential != processed.credential() {
                return Err(Error("authenticated sender credential mismatch".to_owned()));
            }
            let credential =
                BasicCredential::try_from(processed.credential().clone()).map_err(fail)?;
            Some(AuthenticatedSender {
                identity: String::from_utf8(credential.identity().to_vec()).map_err(fail)?,
                public_key: member.signature_key,
            })
        } else {
            None
        };
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                Ok((Received::Application(message.into_bytes()), sender))
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group
                    .merge_staged_commit(&self.provider, *staged)
                    .map_err(fail)?;
                if group.is_active() {
                    Ok((
                        Received::Commit {
                            epoch: group.epoch().as_u64(),
                        },
                        None,
                    ))
                } else {
                    Ok((Received::Removed, None))
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
    hash.as_chunks::<5>()
        .0
        .iter()
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
