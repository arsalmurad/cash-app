//! Explicit deletion permission, separate from saved-state receipts. Public
//! opaque commitments only; never export a private archive or financial fields.
use crate::{
    SyncError,
    peer::{Reader, write_field},
};

const MAGIC: &[u8] = b"cash-app prefix retention consent v1\0";

pub struct PrefixConsentPlan {
    pub policy_epoch: u64,
    pub through: u64,
    pub expires: u64,
    pub recovery_holder: Vec<u8>,
}

pub(crate) struct DecodedConsent {
    pub request: PrefixConsentRequest,
    pub relay_group: [u8; 32],
    pub group: Vec<u8>,
    pub checkpoint: [u8; 32],
    pub signer: Vec<u8>,
    pub signature: Vec<u8>,
    pub payload: Vec<u8>,
}

pub(crate) struct ArchiveContext {
    pub group: Vec<u8>,
    pub relay_group: [u8; 32],
    pub epoch: u64,
    pub checkpoint: [u8; 32],
    pub cutoff: u64,
    pub members: std::collections::BTreeSet<Vec<u8>>,
}

pub(crate) fn decode(bytes: &[u8], now: u64) -> Result<DecodedConsent, SyncError> {
    let invalid = || SyncError("Invalid explicit prefix retention consent.".into());
    if bytes.len() > 1024 {
        return Err(invalid());
    }
    let mut reader = Reader { bytes };
    if reader.take(MAGIC.len()) != Some(MAGIC) {
        return Err(invalid());
    }
    let origin = std::str::from_utf8(reader.field().ok_or_else(invalid)?)
        .map_err(|_| invalid())?
        .to_owned();
    let relay_group = reader.take(32).ok_or_else(invalid)?.try_into().unwrap();
    let group = reader.field().ok_or_else(invalid)?.to_vec();
    let policy_epoch = u64::from_be_bytes(reader.take(8).ok_or_else(invalid)?.try_into().unwrap());
    let through = u64::from_be_bytes(reader.take(8).ok_or_else(invalid)?.try_into().unwrap());
    let checkpoint = reader.take(32).ok_or_else(invalid)?.try_into().unwrap();
    let recovery_holder = reader.take(32).ok_or_else(invalid)?.to_vec();
    let expires = u64::from_be_bytes(reader.take(8).ok_or_else(invalid)?.try_into().unwrap());
    let signer = reader.take(32).ok_or_else(invalid)?.to_vec();
    let signature = reader.take(64).ok_or_else(invalid)?.to_vec();
    if !reader.bytes.is_empty() {
        return Err(invalid());
    }
    let request = PrefixConsentRequest {
        origin,
        policy_epoch,
        through,
        recovery_holder,
        now,
        expires,
    };
    let payload = payload(&request, &relay_group, &group, &checkpoint, &signer)?;
    if payload != bytes[..bytes.len() - 64] {
        return Err(invalid());
    }
    Ok(DecodedConsent {
        request,
        relay_group,
        group,
        checkpoint,
        signer,
        signature,
        payload,
    })
}

#[derive(Clone, Debug)]
pub struct PrefixConsentRequest {
    pub origin: String,
    pub policy_epoch: u64,
    pub through: u64,
    pub recovery_holder: Vec<u8>,
    pub now: u64,
    pub expires: u64,
}

pub(crate) fn payload(
    request: &PrefixConsentRequest,
    relay_group: &[u8; 32],
    mls_group: &[u8],
    checkpoint: &[u8; 32],
    signer: &[u8],
) -> Result<Vec<u8>, SyncError> {
    let invalid = || SyncError("Invalid explicit prefix retention consent.".into());
    if request.through == 0
        || request.through > 999_999_999_999
        || request.policy_epoch > 9_007_199_254_740_991
        || request.recovery_holder.len() != 32
        || signer.len() != 32
        || mls_group.is_empty()
        || mls_group.len() > 256
        || request
            .expires
            .checked_sub(request.now)
            .is_none_or(|ttl| ttl == 0 || ttl > 60_000)
    {
        return Err(invalid());
    }
    // Reuse the actual request codec's canonical HTTPS/owned-loopback origin
    // validation; no request is transmitted and no signing ratchet advances.
    cash_crypto::RelayRequest {
        origin: &request.origin,
        method: "POST",
        path: "/",
        body: &[],
        nonce: [0; 32],
        expires: request.expires,
    }
    .payload(signer)?;
    let mut bytes = MAGIC.to_vec();
    write_field(&mut bytes, request.origin.as_bytes());
    bytes.extend_from_slice(relay_group);
    write_field(&mut bytes, mls_group);
    bytes.extend_from_slice(&request.policy_epoch.to_be_bytes());
    bytes.extend_from_slice(&request.through.to_be_bytes());
    bytes.extend_from_slice(checkpoint);
    bytes.extend_from_slice(&request.recovery_holder);
    bytes.extend_from_slice(&request.expires.to_be_bytes());
    bytes.extend_from_slice(signer);
    Ok(bytes)
}
