use cash_crypto::{Member, Received, safety_number};

/// Adds `joiner` to `adder`'s group and brings every `others` member up to
/// the new epoch, the way the relay's ordered log would.
fn add(adder: &mut Member, joiner: &mut Member, others: &mut [&mut Member]) {
    let invite = adder.add(&joiner.key_package().unwrap()).unwrap();
    adder.confirm_commit().unwrap();
    for member in others {
        assert_eq!(
            member.receive(&invite.commit).unwrap(),
            Received::Commit {
                epoch: adder.epoch()
            }
        );
    }
    joiner.join(&invite.welcome).unwrap();
}

fn three() -> (Member, Member, Member) {
    let mut alice = Member::new("alice").unwrap();
    let mut bob = Member::new("bob").unwrap();
    let mut carol = Member::new("carol").unwrap();
    alice.create_group().unwrap();
    add(&mut alice, &mut bob, &mut []);
    add(&mut alice, &mut carol, &mut [&mut bob]);
    (alice, bob, carol)
}

#[test]
fn three_members_share_one_epoch_and_read_each_others_messages() {
    let (mut alice, mut bob, mut carol) = three();
    assert_eq!(alice.epoch(), bob.epoch());
    assert_eq!(alice.epoch(), carol.epoch());
    assert_eq!(alice.member_names().unwrap(), ["alice", "bob", "carol"]);

    let ciphertext = bob.encrypt(b"rent 900.00").unwrap();
    assert!(!ciphertext.windows(3).any(|window| window == b"900"));
    assert_eq!(
        alice.receive(&ciphertext).unwrap(),
        Received::Application(b"rent 900.00".to_vec())
    );
    assert_eq!(
        carol.receive(&ciphertext).unwrap(),
        Received::Application(b"rent 900.00".to_vec())
    );
}

#[test]
fn a_member_never_decrypts_its_own_message() {
    let (_, mut bob, _) = three();
    let ciphertext = bob.encrypt(b"mine").unwrap();
    assert_eq!(bob.receive(&ciphertext).unwrap(), Received::Own);
}

#[test]
fn an_offline_member_catches_up_by_replaying_the_ordered_stream() {
    let (mut alice, mut bob, mut carol) = three();
    // Carol goes offline; everything below is what the relay retains for her.
    let first = alice.encrypt(b"one").unwrap();
    let invite = alice
        .add(&Member::new("dave").unwrap().key_package().unwrap())
        .unwrap();
    alice.confirm_commit().unwrap();
    bob.receive(&first).unwrap();
    bob.receive(&invite.commit).unwrap();
    let second = bob.encrypt(b"two").unwrap();

    assert_eq!(
        carol.receive(&first).unwrap(),
        Received::Application(b"one".to_vec())
    );
    assert!(matches!(
        carol.receive(&invite.commit).unwrap(),
        Received::Commit { .. }
    ));
    assert_eq!(
        carol.receive(&second).unwrap(),
        Received::Application(b"two".to_vec())
    );
}

#[test]
fn a_removed_member_cannot_decrypt_any_later_epoch() {
    let (mut alice, mut bob, mut carol) = three();
    let commit = alice.remove("bob").unwrap();
    alice.confirm_commit().unwrap();
    carol.receive(&commit).unwrap();
    assert_eq!(bob.receive(&commit).unwrap(), Received::Removed);
    assert!(!bob.is_active());

    let after = alice.encrypt(b"secret after removal").unwrap();
    assert!(bob.receive(&after).is_err());
    assert_eq!(
        carol.receive(&after).unwrap(),
        Received::Application(b"secret after removal".to_vec())
    );

    // Rotation continues: a second commit after the removal is also opaque.
    let again = carol.remove("alice").unwrap();
    carol.confirm_commit().unwrap();
    let later = carol.encrypt(b"later").unwrap();
    assert!(bob.receive(&again).is_err());
    assert!(bob.receive(&later).is_err());
}

#[test]
fn a_discarded_commit_leaves_the_group_usable() {
    let (mut alice, mut bob, mut carol) = three();
    let epoch = alice.epoch();
    // Alice's commit loses the race at the relay and is thrown away.
    alice.remove("carol").unwrap();
    alice.discard_commit().unwrap();
    assert_eq!(alice.epoch(), epoch);
    assert_eq!(alice.member_names().unwrap().len(), 3);

    let ciphertext = alice.encrypt(b"still here").unwrap();
    assert_eq!(
        bob.receive(&ciphertext).unwrap(),
        Received::Application(b"still here".to_vec())
    );
    assert_eq!(
        carol.receive(&ciphertext).unwrap(),
        Received::Application(b"still here".to_vec())
    );
}

#[test]
fn safety_numbers_match_on_both_sides_and_differ_per_pair() {
    let (alice, bob, carol) = three();
    let ab = safety_number(&alice.public_key(), &bob.public_key());
    assert_eq!(ab, safety_number(&bob.public_key(), &alice.public_key()));
    assert_ne!(ab, safety_number(&alice.public_key(), &carol.public_key()));
    // Six groups of five digits, Signal-style.
    let groups: Vec<_> = ab.split(' ').collect();
    assert_eq!(groups.len(), 6);
    assert!(
        groups
            .iter()
            .all(|group| group.len() == 5 && group.bytes().all(|byte| byte.is_ascii_digit()))
    );
}

#[test]
fn a_member_keeps_working_after_a_restart_mid_conversation() {
    let (mut alice, bob, mut carol) = three();
    let before = bob.epoch();

    // Bob's app is killed and relaunched from nothing but its exported state.
    let saved = bob.export().unwrap();
    drop(bob);
    let mut bob = Member::import(&saved).unwrap();
    assert_eq!(bob.epoch(), before);
    assert!(bob.is_active());
    assert_eq!(bob.member_names().unwrap(), ["alice", "bob", "carol"]);

    // He can still read what others send, and they can read him.
    let hello = alice.encrypt(b"welcome back").unwrap();
    assert_eq!(
        bob.receive(&hello).unwrap(),
        Received::Application(b"welcome back".to_vec())
    );
    carol.receive(&hello).unwrap();
    let reply = bob.encrypt(b"thanks").unwrap();
    assert_eq!(
        alice.receive(&reply).unwrap(),
        Received::Application(b"thanks".to_vec())
    );

    // And across an epoch change after the restart.
    let commit = alice.remove("carol").unwrap();
    alice.confirm_commit().unwrap();
    assert!(matches!(
        bob.receive(&commit).unwrap(),
        Received::Commit { .. }
    ));
    let saved = bob.export().unwrap();
    let mut bob = Member::import(&saved).unwrap();
    let after = alice.encrypt(b"two of us").unwrap();
    assert_eq!(
        bob.receive(&after).unwrap(),
        Received::Application(b"two of us".to_vec())
    );
}

#[test]
fn a_restarted_member_still_recognises_its_own_messages_and_identity() {
    let (_, mut bob, _) = three();
    let ciphertext = bob.encrypt(b"mine").unwrap();
    let key = bob.public_key();

    let mut bob = Member::import(&bob.export().unwrap()).unwrap();
    assert_eq!(bob.public_key(), key);
    assert_eq!(bob.receive(&ciphertext).unwrap(), Received::Own);
}

#[test]
fn a_member_without_a_group_round_trips_and_garbage_is_rejected() {
    let fresh = Member::new("dana").unwrap();
    let key = fresh.public_key();
    let restored = Member::import(&fresh.export().unwrap()).unwrap();
    assert_eq!(restored.public_key(), key);
    assert!(!restored.is_active());

    assert!(Member::import(b"not a member").is_err());
    let mut truncated = fresh.export().unwrap();
    truncated.truncate(truncated.len() / 2);
    assert!(Member::import(&truncated).is_err());
}
