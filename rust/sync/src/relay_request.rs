//! Public request metadata only. Proofs do not confer relay membership or
//! permission; the server must check its trusted current device policy.

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceRequestProof {
    pub public_key: Vec<u8>,
    pub nonce: [u8; 32],
    pub expires: u64,
    pub signature: Vec<u8>,
}
