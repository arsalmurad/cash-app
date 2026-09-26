//! Exit-test evidence for the durable event log: byte-identical persistence
//! for a large event set, and safe recovery from a log truncated by a
//! simulated crash.

use cash_core::{
    AccountId, Currency, Event, EventKind, FxRate, Money, TransactionId, TransactionKind,
    decode_event_log, encode_event_frame, fold,
};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn eur() -> Currency {
    Currency::from_code("EUR").unwrap()
}

fn account_event(id: &str, actor: &str, time: i64, account: &str, currency: Currency) -> Event {
    Event::new(
        id,
        actor,
        time,
        0,
        EventKind::AccountOpened {
            account_id: AccountId::new(account),
            name: account.to_owned(),
            currency,
        },
    )
}

fn transaction_event(
    index: usize,
    actor: &str,
    account: &str,
    amount: i64,
    currency: Currency,
    rate: FxRate,
) -> Event {
    Event::new(
        format!("event-{index:04}"),
        actor,
        index as i64,
        0,
        EventKind::TransactionRecorded {
            transaction_id: TransactionId::new(format!("transaction-{index:04}")),
            account_id: AccountId::new(account),
            kind: if index % 5 == 0 {
                TransactionKind::Income
            } else {
                TransactionKind::Expense
            },
            original: Money::new(amount, currency),
            reporting_fx: rate,
            title: format!("Entry {index}"),
            category_id: Some(format!("category-{}", index % 7)),
            recurring_id: None,
        },
    )
}

fn thousand_events() -> Vec<Event> {
    let mut events = vec![
        account_event("event-0000", "alice", 0, "usd-account", usd()),
        account_event("event-0001", "bob", 1, "eur-account", eur()),
    ];
    for index in 2..1000 {
        let (actor, account, currency, rate) = if index % 2 == 0 {
            ("alice", "usd-account", usd(), FxRate::identity(usd()))
        } else {
            (
                "bob",
                "eur-account",
                eur(),
                FxRate::new(110 + (index % 3) as i64, 100, usd()).unwrap(),
            )
        };
        events.push(transaction_event(
            index,
            actor,
            account,
            100 + index as i64,
            currency,
            rate,
        ));
    }
    events
}

fn append_all(events: &[Event]) -> Vec<u8> {
    let mut log = Vec::new();
    for event in events {
        log.extend(encode_event_frame(event));
    }
    log
}

#[test]
fn a_persisted_log_of_one_thousand_events_folds_identically_to_the_in_memory_events() {
    let events = thousand_events();
    let in_memory_state = fold(usd(), events.clone()).unwrap();

    let log = append_all(&events);
    let decoded = decode_event_log(&log);
    assert_eq!(decoded.trailing_garbage_bytes, 0);
    assert_eq!(decoded.events.len(), events.len());

    let restarted_state = fold(usd(), decoded.events).unwrap();
    assert_eq!(restarted_state, in_memory_state);
    assert_eq!(
        restarted_state.canonical_bytes(),
        in_memory_state.canonical_bytes()
    );
}

#[test]
fn restarting_from_a_log_truncated_mid_write_recovers_every_complete_event() {
    let events = thousand_events();
    let mut log = append_all(&events[..999]);
    let complete_len = log.len();

    // A crash while flushing event 999's frame: only its first half reached
    // durable storage.
    let mut torn_frame = encode_event_frame(&events[999]);
    torn_frame.truncate(torn_frame.len() / 2);
    log.extend(&torn_frame);

    let decoded = decode_event_log(&log);
    assert_eq!(decoded.events, events[..999]);
    assert_eq!(decoded.trailing_garbage_bytes, log.len() - complete_len);

    // The recovered prefix must still fold cleanly and match a full fold of
    // the same prefix computed directly from memory, i.e. restart lost
    // exactly the one unflushed event and nothing else.
    let recovered_state = fold(usd(), decoded.events).unwrap();
    let expected_state = fold(usd(), events[..999].to_vec()).unwrap();
    assert_eq!(recovered_state, expected_state);
}

#[test]
fn a_write_the_ledger_would_reject_is_never_part_of_a_valid_persisted_log() {
    // Two AccountOpened events reusing the same account ID with different
    // content: `fold` rejects this as a conflicting duplicate. A correct
    // append-only writer would refuse to persist the second event's frame in
    // the first place, so decoding a log that (by construction) never
    // contained the rejected event must fold cleanly.
    let accepted = account_event("account", "alice", 0, "checking", usd());
    let log = encode_event_frame(&accepted);

    let decoded = decode_event_log(&log);
    assert_eq!(decoded.trailing_garbage_bytes, 0);
    let state = fold(usd(), decoded.events).unwrap();
    assert_eq!(state.accounts.len(), 1);

    // Proving the rejection itself: had the conflicting event been persisted
    // too, replaying the log would fail instead of silently overwriting.
    let rejected = account_event("account", "alice", 0, "savings", usd());
    let mut log_with_rejected_event = log;
    log_with_rejected_event.extend(encode_event_frame(&rejected));
    let decoded_with_conflict = decode_event_log(&log_with_rejected_event);
    assert!(fold(usd(), decoded_with_conflict.events).is_err());
}
