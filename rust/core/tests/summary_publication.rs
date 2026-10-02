use cash_core::{
    ChosenSummary, Currency, Event, EventKind, SharedEvent, SharedSnapshot, SnapshotUpdate,
    decode_event_log, decode_shared_event, encode_event_frame, encode_shared_event, fold_shared,
};

fn currency(code: &str) -> Currency {
    Currency::from_code(code).unwrap()
}

fn publication(
    id: &str,
    actor: &str,
    time: i64,
    income: Option<i64>,
    expenses: Option<i64>,
) -> SharedEvent {
    SharedEvent {
        event: Event::new(
            id,
            actor,
            time,
            0,
            EventKind::SummaryPublished {
                summary: ChosenSummary::new(currency("JPY"), 10, 20, income, expenses).unwrap(),
            },
        ),
        base: None,
    }
}

#[test]
fn publication_round_trips_without_accounts_private_metadata_or_balance_changes() {
    let shared = publication("public-id", "household-author", 30, None, Some(123));
    let wire = encode_shared_event(&shared);
    assert_eq!(decode_shared_event(&wire), Some(shared.clone()));
    let frame = encode_event_frame(&shared.event);
    let decoded = decode_event_log(&frame);
    assert_eq!(decoded.events, std::slice::from_ref(&shared.event));
    assert_eq!(decoded.trailing_garbage_bytes, 0);
    let state = fold_shared(currency("USD"), [shared.clone(), shared]);
    assert!(state.rejected.is_empty());
    assert!(state.ledger.accounts.is_empty());
    assert!(state.ledger.transactions.is_empty());
    assert!(state.ledger.transfers.is_empty());
    assert_eq!(state.ledger.reporting_balance_minor, 0);
    let published = state.ledger.summaries.values().next().unwrap();
    assert_eq!(published.summary.currency(), &currency("JPY"));
    assert_eq!(published.summary.income_minor(), None);
    assert_eq!(published.summary.expenses_minor(), Some(123));
    assert_eq!(published.actor_id.as_str(), "household-author");
    assert_eq!(published.timestamp.physical_millis, 30);
}

#[test]
fn summaries_survive_duplicate_late_arrival_and_checked_checkpoint_rebuild() {
    let first = publication("first", "alice", 30, Some(5), None);
    let late = publication("late", "bob", 25, None, Some(8));
    let expected = fold_shared(currency("USD"), [late.clone(), first.clone()]);
    let reversed = fold_shared(currency("USD"), [first.clone(), late.clone()]);
    assert_eq!(expected.canonical_bytes(), reversed.canonical_bytes());
    let mut checkpoint = SharedSnapshot::from_events(currency("USD"), [first.clone()]);
    assert_eq!(checkpoint.extend([late.clone()]), SnapshotUpdate::Rebuilt);
    assert_eq!(checkpoint.extend([first]), SnapshotUpdate::Unchanged);
    assert_eq!(
        checkpoint.state().canonical_bytes(),
        expected.canonical_bytes()
    );
    assert_eq!(checkpoint.causal_frontier().len(), 2);
    assert_eq!(
        checkpoint.checkpoint_bytes(),
        SharedSnapshot::from_events(
            currency("USD"),
            [late, publication("first", "alice", 30, Some(5), None)]
        )
        .checkpoint_bytes()
    );
}

#[test]
fn contradictory_publication_with_same_event_id_is_visible_not_overwritten() {
    let state = fold_shared(
        currency("USD"),
        [
            publication("same", "alice", 30, Some(1), None),
            publication("same", "alice", 30, Some(2), None),
        ],
    );
    assert_eq!(state.rejected.len(), 1);
    assert!(state.ledger.summaries.is_empty());
    assert_eq!(state.ledger.reporting_balance_minor, 0);
}

#[test]
fn invalid_period_and_empty_disclosures_are_rejected_by_the_wire_decoder() {
    let shared = publication("public-id", "alice", 30, None, Some(123));
    let bytes = encode_shared_event(&shared);
    let start = bytes
        .windows(16)
        .position(|window| {
            window[..8] == 10_i64.to_be_bytes() && window[8..] == 20_i64.to_be_bytes()
        })
        .unwrap();
    let mut invalid = bytes.clone();
    invalid[start + 8..start + 16].copy_from_slice(&10_i64.to_be_bytes());
    assert!(decode_shared_event(&invalid).is_none());
    // Currency/start/end are followed by two presence flags; neither selected.
    let mut empty = bytes[..start + 16].to_vec();
    empty.extend_from_slice(&[0, 0]);
    assert!(decode_shared_event(&empty).is_none());
}

#[test]
fn no_publications_preserves_the_previous_empty_canonical_ledger_bytes() {
    let state = fold_shared(currency("USD"), []);
    // Old shape: currency string, balance, account/transaction/transfer counts.
    let mut expected = 3_u64.to_be_bytes().to_vec();
    expected.extend_from_slice(b"USD");
    expected.extend_from_slice(&[0; 32]);
    assert_eq!(state.ledger.canonical_bytes(), expected);
}
