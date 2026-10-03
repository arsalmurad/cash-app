//! Detached device request proof only; caller/server still owe authorization,
//! freshness, nonce admission and quotas. No MLS ratchet is advanced here.
use openmls_traits::{OpenMlsProvider, crypto::OpenMlsCrypto, signatures::Signer};
use url::{Host, Url};

use super::{CIPHERSUITE, Error, Member, digest, fail, write_field};

#[derive(Clone, Copy)]
pub struct RelayRequest<'a> {
    pub origin: &'a str,
    pub method: &'a str,
    pub path: &'a str,
    pub body: &'a [u8],
    pub nonce: [u8; 32],
    pub expires: u64,
}

impl RelayRequest<'_> {
    /// Matches `relay/src/request-proof.js`, including canonical URL spelling.
    /// Public device keys and all request metadata are linkable, not financial.
    pub fn payload(&self, public_key: &[u8]) -> Result<Vec<u8>, Error> {
        let invalid = || Error("invalid or noncanonical relay request fields".to_owned());
        if self.origin.len() > 256
            || self.path.len() > 1024
            || !self.path.starts_with('/')
            || self.body.len() > 512 * 1024
            || !["GET", "POST", "PUT"].contains(&self.method)
            || public_key.len() != 32
            || self.expires > 9_007_199_254_740_991
        {
            return Err(invalid());
        }
        let base = Url::parse(self.origin).map_err(|_| invalid())?;
        let local = match base.host() {
            Some(Host::Domain("localhost")) => true,
            Some(Host::Ipv4(ip)) => ip.octets() == [127, 0, 0, 1],
            Some(Host::Ipv6(ip)) => ip == std::net::Ipv6Addr::LOCALHOST,
            _ => false,
        };
        let joined = base.join(self.path).map_err(|_| invalid())?;
        if base.origin().ascii_serialization() != self.origin
            || !(base.scheme() == "https" || (base.scheme() == "http" && local))
            || joined.origin() != base.origin()
            || joined.fragment().is_some()
            || joined.query() == Some("")
            || joined.as_str().strip_prefix(self.origin) != Some(self.path)
        {
            return Err(invalid());
        }
        let mut payload = b"cash-app authenticated relay request v1\0".to_vec();
        for field in [
            self.origin.as_bytes(),
            self.method.as_bytes(),
            self.path.as_bytes(),
            &digest(self.body),
            public_key,
            &self.nonce,
        ] {
            write_field(&mut payload, field);
        }
        payload.extend_from_slice(&self.expires.to_be_bytes());
        Ok(payload)
    }
}

impl Member {
    /// Uses the protected existing device identity, including before joining.
    /// Freshness/replay checks are server responsibilities, not membership proof.
    pub fn sign_relay_request(&self, request: &RelayRequest<'_>) -> Result<Vec<u8>, Error> {
        self.signer
            .sign(&request.payload(self.signer.public())?)
            .map_err(fail)
    }

    pub fn verify_relay_request(
        &self,
        public_key: &[u8],
        request: &RelayRequest<'_>,
        signature: &[u8],
    ) -> Result<(), Error> {
        self.provider
            .crypto()
            .verify_signature(
                CIPHERSUITE.signature_algorithm(),
                &request.payload(public_key)?,
                public_key,
                signature,
            )
            .map_err(fail)
    }
}
