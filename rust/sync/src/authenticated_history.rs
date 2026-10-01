use cash_core::{EventId, SharedEvent, decode_shared_event, encode_shared_event};
use cash_crypto::{Member, author_id};
use sha2::{Digest, Sha256};

use crate::peer::{Reader, SyncError, write_field};

const MAGIC: &[u8] = b"cash-app signed event v1\0";
const MAX_EVENT_BYTES: usize = 64 * 1024;

/// Original authorship proof, preserved verbatim by every forwarding peer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SignedEvent {
    pub shared: SharedEvent,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

impl SignedEvent {
    /// Distinct valid proofs for a conflicting event ID must both survive
    /// backfill and restart so the fold can expose the conflict consistently.
    pub fn proof_id(&self) -> EventId {
        let hash = Sha256::digest(self.encode());
        EventId::new(
            hash.iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>(),
        )
    }
    pub fn sign(member: &Member, shared: SharedEvent) -> Result<Self, SyncError> {
        let mut signed = Self {
            shared,
            public_key: member.public_key(),
            signature: Vec::new(),
        };
        signed.check_identity()?;
        let payload = encode_shared_event(&signed.shared);
        if payload.len() > MAX_EVENT_BYTES {
            return Err(SyncError(
                "shared event exceeds the signed-event size limit".to_owned(),
            ));
        }
        signed.signature = member.sign_history(&payload)?;
        Ok(signed)
    }

    fn check_identity(&self) -> Result<(), SyncError> {
        let actor = author_id(&self.public_key);
        if self.public_key.len() != 32
            || self.shared.event.actor_id.as_str() != actor
            || !self
                .shared
                .event
                .id
                .as_str()
                .starts_with(&format!("{actor}-"))
        {
            return Err(SyncError(
                "event author or ID does not match its signing key".to_owned(),
            ));
        }
        Ok(())
    }

    pub fn verify(&self, member: &Member) -> Result<(), SyncError> {
        self.check_identity()?;
        member.verify_history(
            &self.public_key,
            &encode_shared_event(&self.shared),
            &self.signature,
        )?;
        Ok(())
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = MAGIC.to_vec();
        write_field(&mut bytes, &encode_shared_event(&self.shared));
        write_field(&mut bytes, &self.public_key);
        write_field(&mut bytes, &self.signature);
        bytes
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let mut reader = Reader { bytes };
        if reader.take(MAGIC.len())? != MAGIC {
            return None;
        }
        let event_bytes = reader.field()?;
        if event_bytes.len() > MAX_EVENT_BYTES {
            return None;
        }
        let shared = decode_shared_event(event_bytes)?;
        if encode_shared_event(&shared) != event_bytes {
            return None;
        }
        let public_key = reader.field()?;
        let signature = reader.field()?;
        if public_key.len() != 32 || signature.len() != 64 || !reader.bytes.is_empty() {
            return None;
        }
        Some(Self {
            shared,
            public_key: public_key.to_vec(),
            signature: signature.to_vec(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cash_core::{AccountId, Currency, Event, EventKind, SharedEvent};

    fn household() -> (Member, Member) {
        let mut alice = Member::new("alice").unwrap();
        let mut bob = Member::new("bob").unwrap();
        alice.create_group().unwrap();
        let invite = alice.add(&bob.key_package().unwrap()).unwrap();
        alice.confirm_commit().unwrap();
        bob.join(&invite.welcome).unwrap();
        (alice, bob)
    }

    fn event(member: &Member) -> SharedEvent {
        let actor = author_id(&member.public_key());
        SharedEvent {
            event: Event::new(
                format!("{actor}-event"),
                actor,
                1,
                0,
                EventKind::AccountOpened {
                    account_id: AccountId::new("joint"),
                    name: "Joint".to_owned(),
                    currency: Currency::from_code("USD").unwrap(),
                },
            ),
            base: None,
        }
    }

    #[test]
    fn proof_round_trips_and_a_different_member_can_forward_it() {
        let (alice, bob) = household();
        let original = event(&alice);
        let proof = SignedEvent::sign(&alice, original.clone()).unwrap();
        let restored = SignedEvent::decode(&proof.encode()).unwrap();
        restored.verify(&bob).unwrap();
        assert_eq!(restored.shared, original);
        let mut trailing = proof.encode();
        trailing.push(0);
        assert!(SignedEvent::decode(&trailing).is_none());
    }

    #[test]
    fn a_household_member_cannot_sign_in_another_authors_name_or_id_namespace() {
        let (alice, bob) = household();
        assert!(SignedEvent::sign(&bob, event(&alice)).is_err());
        let mut wrong_id = event(&bob);
        wrong_id.event.id = event(&alice).event.id;
        assert!(SignedEvent::sign(&bob, wrong_id).is_err());
    }

    #[test]
    fn changing_the_event_author_base_or_signature_invalidates_the_proof() {
        let (alice, bob) = household();
        let proof = SignedEvent::sign(&alice, event(&alice)).unwrap();
        let mut changed = proof.clone();
        changed.shared.base = Some(cash_core::EventId::new("forged-base"));
        assert!(changed.verify(&bob).is_err());
        let mut changed = proof.clone();
        changed.public_key = bob.public_key();
        assert!(changed.verify(&bob).is_err());
        let mut changed = proof;
        changed.signature[0] ^= 1;
        assert!(changed.verify(&bob).is_err());
    }
}
