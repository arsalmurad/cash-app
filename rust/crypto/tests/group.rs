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
