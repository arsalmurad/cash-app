use std::fmt::Debug;

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

pub(crate) struct SpikeState {
    alice_provider: OpenMlsRustCrypto,
    bob_provider: OpenMlsRustCrypto,
    alice_signer: SignatureKeyPair,
    alice_group: MlsGroup,
    bob_group: Option<MlsGroup>,
}

fn describe_error(error: impl Debug) -> String {
    format!("{error:?}")
}

fn identity(
    provider: &OpenMlsRustCrypto,
    name: &[u8],
) -> Result<(CredentialWithKey, SignatureKeyPair), String> {
    let signer =
        SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(describe_error)?;
    signer.store(provider.storage()).map_err(describe_error)?;
    let credential = CredentialWithKey {
        credential: BasicCredential::new(name.to_vec()).into(),
        signature_key: signer.public().into(),
    };
    Ok((credential, signer))
}

impl SpikeState {
    pub(crate) fn new() -> Result<Self, String> {
        let alice_provider = OpenMlsRustCrypto::default();
        let bob_provider = OpenMlsRustCrypto::default();
        let (alice_credential, alice_signer) = identity(&alice_provider, b"Alice")?;
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();
        let alice_group = MlsGroup::new(&alice_provider, &alice_signer, &config, alice_credential)
            .map_err(describe_error)?;
        Ok(Self {
            alice_provider,
            bob_provider,
            alice_signer,
            alice_group,
            bob_group: None,
        })
    }

    pub(crate) fn add_member(&mut self) -> Result<bool, String> {
        if self.bob_group.is_some() {
            return Err("Bob is already in the group".to_owned());
        }
        let (bob_credential, bob_signer) = identity(&self.bob_provider, b"Bob")?;
        let bob_key_package = KeyPackage::builder()
            .build(CIPHERSUITE, &self.bob_provider, &bob_signer, bob_credential)
            .map_err(describe_error)?;

        let (_, welcome, _) = self
            .alice_group
            .add_members(
                &self.alice_provider,
                &self.alice_signer,
                &[bob_key_package.key_package().clone()],
            )
            .map_err(describe_error)?;
        self.alice_group
            .merge_pending_commit(&self.alice_provider)
            .map_err(describe_error)?;

        let welcome_in: MlsMessageIn = welcome.into();
        let welcome = match welcome_in.extract() {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => return Err("OpenMLS produced a non-Welcome response".to_owned()),
        };
        let join_config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .build();
        let mut bob_group =
            StagedWelcome::new_from_welcome(&self.bob_provider, &join_config, welcome, None)
                .map_err(describe_error)?
                .into_group(&self.bob_provider)
                .map_err(describe_error)?;

        let before: MlsMessageIn = self
            .alice_group
            .create_message(&self.alice_provider, &self.alice_signer, b"before removal")
            .map_err(describe_error)?
            .into();
        let processed = bob_group
            .process_message(
                &self.bob_provider,
                before.try_into_protocol_message().map_err(describe_error)?,
            )
            .map_err(describe_error)?;
        let decrypted = match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                message.into_bytes() == b"before removal"
            }
            _ => false,
        };
        if !decrypted {
            return Err("Bob failed to decrypt before removal".to_owned());
        }
        self.bob_group = Some(bob_group);
        Ok(true)
    }

    pub(crate) fn remove_member_and_verify(&mut self) -> Result<bool, String> {
        let bob_group = self
            .bob_group
            .as_mut()
            .ok_or_else(|| "Add Bob before removing him".to_owned())?;
        if !bob_group.is_active() {
            return Err("Bob is already inactive".to_owned());
        }
        let own_index = self.alice_group.own_leaf_index();
        let bob_index = self
            .alice_group
            .members()
            .find(|member| member.index != own_index)
            .map(|member| member.index)
            .ok_or_else(|| "Bob is missing from Alice's group".to_owned())?;
        let (commit, _, _) = self
            .alice_group
            .remove_members(&self.alice_provider, &self.alice_signer, &[bob_index])
            .map_err(describe_error)?;
        self.alice_group
            .merge_pending_commit(&self.alice_provider)
            .map_err(describe_error)?;

        let commit_in: MlsMessageIn = commit.into();
        let processed = bob_group
            .process_message(
                &self.bob_provider,
                commit_in
                    .try_into_protocol_message()
                    .map_err(describe_error)?,
            )
            .map_err(describe_error)?;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged) => bob_group
                .merge_staged_commit(&self.bob_provider, *staged)
                .map_err(describe_error)?,
            _ => return Err("Removal was not a staged commit".to_owned()),
        }

        let after: MlsMessageIn = self
            .alice_group
            .create_message(&self.alice_provider, &self.alice_signer, b"after removal")
            .map_err(describe_error)?
            .into();
        let rejected = bob_group
            .process_message(
                &self.bob_provider,
                after.try_into_protocol_message().map_err(describe_error)?,
            )
            .is_err();
        Ok(self.alice_group.members().count() == 1 && !bob_group.is_active() && rejected)
    }
}

#[cfg(test)]
mod tests {
    use super::SpikeState;

    #[test]
    fn removed_member_cannot_decrypt_next_epoch() {
        let mut state = SpikeState::new().expect("create group");
        assert!(state
            .add_member()
            .expect("add Bob and decrypt before removal"));
        assert!(state
            .remove_member_and_verify()
            .expect("remove Bob and reject next-epoch message"));
    }
}
