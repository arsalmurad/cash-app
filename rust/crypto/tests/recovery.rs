use cash_crypto::{RecoveryError, RecoveryKey};

#[test]
fn a_recovery_phrase_is_twenty_four_words_and_round_trips() {
    let key = RecoveryKey::generate();
    let phrase = key.phrase();
    assert_eq!(phrase.split(' ').count(), 24);
    assert!(
        phrase
            .split(' ')
            .all(|word| word.chars().all(|c| c.is_ascii_lowercase()))
    );

    let restored = RecoveryKey::from_phrase(&phrase).unwrap();
    assert_eq!(restored.phrase(), phrase);
}

#[test]
fn phrases_are_random_per_key() {
    assert_ne!(
        RecoveryKey::generate().phrase(),
        RecoveryKey::generate().phrase()
    );
}

#[test]
fn a_mistyped_phrase_is_rejected_not_silently_accepted() {
    let phrase = RecoveryKey::generate().phrase();
    let words: Vec<_> = phrase.split(' ').collect();

    // A word not in the list.
    let mut bad = words.clone();
    bad[5] = "zzzzzz";
    assert!(RecoveryKey::from_phrase(&bad.join(" ")).is_err());

    // Two words swapped: valid words, broken checksum (unless they match).
    let mut swapped = words.clone();
    swapped.swap(0, 1);
    if swapped != words {
        assert!(RecoveryKey::from_phrase(&swapped.join(" ")).is_err());
    }

    // Too short.
    assert!(RecoveryKey::from_phrase(&words[..23].join(" ")).is_err());
    assert!(RecoveryKey::from_phrase("").is_err());

    // Case and extra whitespace are forgiven: people type these by hand.
    let sloppy = format!("  {}  ", phrase.to_uppercase().replace(' ', "   "));
    assert_eq!(RecoveryKey::from_phrase(&sloppy).unwrap().phrase(), phrase);
}

#[test]
fn sealed_backups_open_only_with_the_same_key() {
    let key = RecoveryKey::generate();
    let backup = b"private ledger and group state".to_vec();
    let sealed = key.seal(&backup).unwrap();
    assert!(!sealed.windows(6).any(|window| window == b"ledger"));
    assert_eq!(key.open(&sealed).unwrap(), backup);

    // The restored key from the written-down phrase opens it.
    let restored = RecoveryKey::from_phrase(&key.phrase()).unwrap();
    assert_eq!(restored.open(&sealed).unwrap(), backup);

    let other = RecoveryKey::generate();
    assert_eq!(other.open(&sealed), Err(RecoveryError::CannotOpen));
}

#[test]
fn sealing_is_randomised_and_tampering_is_detected() {
    let key = RecoveryKey::generate();
    let first = key.seal(b"same").unwrap();
    let second = key.seal(b"same").unwrap();
    assert_ne!(first, second, "each seal uses a fresh nonce");

    for index in 0..first.len() {
        let mut damaged = first.clone();
        damaged[index] ^= 1;
        assert!(
            key.open(&damaged).is_err(),
            "flipping byte {index} went unnoticed"
        );
    }
    assert!(key.open(&first[..first.len() - 1]).is_err());
    assert!(key.open(&[]).is_err());
    assert_eq!(key.open(&first).unwrap(), b"same");
}

#[test]
fn an_empty_backup_seals_and_opens() {
    let key = RecoveryKey::generate();
    assert_eq!(key.open(&key.seal(b"").unwrap()).unwrap(), b"");
}
