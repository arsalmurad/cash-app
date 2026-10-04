//! Explicit deletion permission, separate from saved-state receipts. Public
//! opaque commitments only; never export a private archive or financial fields.
use crate::{SyncError, peer::write_field};

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
    let mut bytes = b"cash-app prefix retention consent v1\0".to_vec();
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
