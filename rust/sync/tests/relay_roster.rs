use cash_core::Currency;
use cash_sync::Peer;

fn peer(id: &str) -> Peer {
    Peer::new(id, Currency::from_code("USD").unwrap()).unwrap()
}

#[test]
fn unjoined_roster_is_refused_and_found_roster_contains_only_public_signing_key() {
    let mut alice = peer("private-name-alice");
    let saved = alice.export().unwrap();
    assert!(alice.relay_roster_keys().is_err());
    assert_eq!(alice.export().unwrap(), saved);
    alice.found_group().unwrap();
    let saved = alice.export().unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), vec![alice.public_key()]);
    assert_eq!(alice.export().unwrap(), saved);
}

#[test]
fn staged_invite_projects_exact_committed_keys_without_advancing_original_epoch() {
    let mut alice = peer("private-name-alice");
    let group = alice.found_group().unwrap();
    let mut bob = peer("private-name-bob");
    let package = bob.key_package().unwrap();
    let invite = alice.begin_invite(&package).unwrap();
    let mut expected = vec![alice.public_key(), bob.public_key()];
    expected.sort();
    let saved = alice.export().unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), expected);
    assert_eq!(alice.member_keys().unwrap().len(), 1);
    assert_eq!(alice.export().unwrap(), saved);
    let mut restarted = Peer::import(&saved).unwrap();
    assert_eq!(restarted.relay_roster_keys().unwrap(), expected);
    assert_eq!(restarted.export().unwrap(), saved);
    restarted.commit_rejected().unwrap();
    assert_eq!(
        restarted.relay_roster_keys().unwrap(),
        vec![alice.public_key()]
    );
    alice.commit_accepted(1).unwrap();
    bob.join(&group, &invite.welcome, 1).unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), expected);
    assert_eq!(bob.relay_roster_keys().unwrap(), expected);
}

#[test]
fn staged_removal_excludes_only_target_and_survives_restart_and_rejection() {
    let mut alice = peer("private-name-alice");
    let group = alice.found_group().unwrap();
    let mut bob = peer("private-name-bob");
    let invite = alice.begin_invite(&bob.key_package().unwrap()).unwrap();
    alice.commit_accepted(1).unwrap();
    bob.join(&group, &invite.welcome, 1).unwrap();
    let current = alice.relay_roster_keys().unwrap();
    alice.begin_removal("private-name-bob").unwrap();
    let saved = alice.export().unwrap();
    let expected = vec![alice.public_key()];
    assert_eq!(alice.relay_roster_keys().unwrap(), expected);
    assert_eq!(alice.member_keys().unwrap().len(), 2);
    assert_eq!(alice.export().unwrap(), saved);
    let mut alice = Peer::import(&saved).unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), expected);
    assert_eq!(alice.export().unwrap(), saved);
    alice.commit_rejected().unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), current);
    let removal = alice.begin_removal("private-name-bob").unwrap();
    alice.commit_accepted(2).unwrap();
    assert_eq!(alice.relay_roster_keys().unwrap(), expected);
    bob.ingest(&[(2, removal.blob)]).unwrap();
    assert!(!bob.is_member());
    let removed = bob.export().unwrap();
    assert!(bob.relay_roster_keys().is_err());
    assert_eq!(bob.export().unwrap(), removed);
}

#[test]
fn projected_roster_refuses_a_sixty_fifth_key_without_confirming_or_mutating_it() {
    let mut alice = peer("alice");
    alice.found_group().unwrap();
    for index in 1..64 {
        let other = peer(&format!("synthetic-device-{index}"));
        alice.begin_invite(&other.key_package().unwrap()).unwrap();
        assert_eq!(alice.relay_roster_keys().unwrap().len(), index + 1);
        alice.commit_accepted(index as u64).unwrap();
    }
    let current = alice.relay_roster_keys().unwrap();
    assert_eq!(current.len(), 64);
    let extra = peer("synthetic-device-65");
    alice.begin_invite(&extra.key_package().unwrap()).unwrap();
    let staged = alice.export().unwrap();
    assert!(alice.relay_roster_keys().is_err());
    assert_eq!(alice.export().unwrap(), staged);
    let mut restarted = Peer::import(&staged).unwrap();
    assert!(restarted.relay_roster_keys().is_err());
    assert_eq!(restarted.export().unwrap(), staged);
    restarted.commit_rejected().unwrap();
    assert_eq!(restarted.relay_roster_keys().unwrap(), current);
}
