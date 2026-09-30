//! Phase 2 exit-test properties for the shared ledger fold: every peer that
//! holds the same set of events reaches byte-identical state, whatever order
//! the events arrived in, and conflicts stay visible instead of being
//! silently overwritten.

use cash_core::{
    AccountId, Conflict, Currency, EditField, Event, EventId, EventKind, FxRate, Money,
    RejectReason, SharedEvent, TransactionId, TransactionKind, decode_shared_event, encode_shared_event,
    fold_shared,
};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn eur() -> Currency {
    Currency::from_code("EUR").unwrap()
}

fn shared(event: Event, base: Option<&str>) -> SharedEvent {
    SharedEvent {
        event,
        base: base.map(EventId::new),
    }
}

fn open_account(
    id: &str,
    actor: &str,
    time: i64,
    account: &str,
    currency: Currency,
) -> SharedEvent {
    shared(
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
        ),
        None,
    )
}

fn record(
    id: &str,
    actor: &str,
    time: i64,
    transaction: &str,
    account: &str,
    minor: i64,
) -> SharedEvent {
    shared(
        Event::new(
            id,
            actor,
            time,
            0,
            EventKind::TransactionRecorded {
                transaction_id: TransactionId::new(transaction),
                account_id: AccountId::new(account),
                kind: TransactionKind::Expense,
                original: Money::new(minor, usd()),
                reporting_fx: FxRate::identity(usd()),
                title: transaction.to_owned(),
                category_id: None,
                recurring_id: None,
            },
        ),
        None,
    )
}

fn adjust(
    id: &str,
    actor: &str,
    time: i64,
    transaction: &str,
    minor: i64,
    base: &str,
) -> SharedEvent {
    shared(
        Event::new(
            id,
            actor,
            time,
            0,
            EventKind::AmountAdjusted {
                transaction_id: TransactionId::new(transaction),
                original: Money::new(minor, usd()),
                reporting_fx: FxRate::identity(usd()),
            },
        ),
        Some(base),
    )
}

fn void(id: &str, actor: &str, time: i64, transaction: &str, base: &str) -> SharedEvent {
    shared(
        Event::new(
            id,
            actor,
            time,
            0,
            EventKind::TransactionVoided {
                transaction_id: TransactionId::new(transaction),
            },
        ),
        Some(base),
    )
}

fn shuffle<T>(values: &mut [T], mut state: u64) {
    for index in (1..values.len()).rev() {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        values.swap(index, (state as usize) % (index + 1));
    }
}

fn balance(events: Vec<SharedEvent>) -> i64 {
    fold_shared(usd(), events).ledger.reporting_balance_minor
}

#[test]
fn concurrent_edits_to_one_expense_both_stay_visible_and_the_later_one_wins() {
    let events = vec![
        open_account("a0", "alice", 1, "joint", usd()),
        record("r1", "alice", 2, "dinner", "joint", 4_000),
        // Alice and Bob both edit what they saw (the original record).
        adjust("e-alice", "alice", 10, "dinner", 4_500, "r1"),
        adjust("e-bob", "bob", 11, "dinner", 4_200, "r1"),
    ];
    let state = fold_shared(usd(), events.clone());

    // Expense of 42.00 (the later edit in total order), not silently 45.00.
    assert_eq!(state.ledger.reporting_balance_minor, -4_200);
    assert_eq!(
        state.conflicts,
        vec![Conflict {
            transaction_id: TransactionId::new("dinner"),
            overwritten: EventId::new("e-alice"),
            winner: EventId::new("e-bob"),
        }]
    );
    assert!(state.rejected.is_empty());

    // Arrival order changes nothing, down to the byte.
    let mut reversed = events;
    reversed.reverse();
    assert_eq!(
        fold_shared(usd(), reversed).canonical_bytes(),
        state.canonical_bytes()
    );
}

#[test]
fn a_sequential_edit_that_saw_the_previous_one_is_not_a_conflict() {
    let state = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            record("r1", "alice", 2, "dinner", "joint", 4_000),
            adjust("e1", "alice", 10, "dinner", 4_500, "r1"),
            adjust("e2", "bob", 11, "dinner", 4_200, "e1"),
        ],
    );
    assert_eq!(state.ledger.reporting_balance_minor, -4_200);
    assert!(state.conflicts.is_empty());
}

#[test]
fn an_edit_ordered_after_a_concurrent_void_is_rejected_visibly() {
    let events = vec![
        open_account("a0", "alice", 1, "joint", usd()),
        record("r1", "alice", 2, "dinner", "joint", 4_000),
        void("v-alice", "alice", 10, "dinner", "r1"),
        adjust("e-bob", "bob", 11, "dinner", 4_200, "r1"),
    ];
    let state = fold_shared(usd(), events.clone());

    assert_eq!(state.ledger.reporting_balance_minor, 0, "the void wins");
    assert!(state.ledger.transactions[&TransactionId::new("dinner")].voided);
    assert_eq!(state.rejected.len(), 1);
    assert_eq!(state.rejected[0].event_id, EventId::new("e-bob"));
    assert!(matches!(state.rejected[0].reason, RejectReason::Fold(_)));

    let mut reversed = events;
    reversed.reverse();
    assert_eq!(
        fold_shared(usd(), reversed).canonical_bytes(),
        state.canonical_bytes()
    );
}

#[test]
fn an_edit_ordered_before_a_concurrent_void_is_absorbed_by_it() {
    let events = vec![
        open_account("a0", "alice", 1, "joint", usd()),
        record("r1", "alice", 2, "dinner", "joint", 4_000),
        adjust("e-bob", "bob", 10, "dinner", 4_200, "r1"),
        void("v-alice", "alice", 11, "dinner", "r1"),
    ];
    let state = fold_shared(usd(), events);
    assert_eq!(state.ledger.reporting_balance_minor, 0);
    assert!(state.ledger.transactions[&TransactionId::new("dinner")].voided);
    assert!(state.rejected.is_empty());
}

#[test]
fn an_invalid_event_is_rejected_visibly_and_does_not_poison_the_rest() {
    let state = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            record("bad", "mallory", 2, "ghost", "no-such-account", 100),
            record("good", "alice", 3, "coffee", "joint", 350),
        ],
    );
    assert_eq!(state.ledger.reporting_balance_minor, -350);
    assert_eq!(state.rejected.len(), 1);
    assert_eq!(state.rejected[0].event_id, EventId::new("bad"));
}

#[test]
fn identical_duplicates_are_idempotent_and_conflicting_duplicates_are_dropped_visibly() {
    let first = record("r1", "alice", 2, "dinner", "joint", 4_000);
    let state = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            first.clone(),
            first.clone(),
        ],
    );
    assert_eq!(state.ledger.reporting_balance_minor, -4_000);
    assert!(state.rejected.is_empty());

    let forged = record("r1", "alice", 2, "dinner", "joint", 1);
    let forward = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            first.clone(),
            forged.clone(),
        ],
    );
    let backward = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            forged,
            first,
        ],
    );
    assert_eq!(forward.canonical_bytes(), backward.canonical_bytes());
    assert_eq!(forward.ledger.reporting_balance_minor, 0);
    assert_eq!(forward.rejected.len(), 1);
    assert!(matches!(
        forward.rejected[0].reason,
        RejectReason::ConflictingDuplicate
    ));
}

#[test]
fn a_thousand_interleaved_events_fold_byte_identically_in_any_order() {
    let mut events = vec![
        open_account("a-usd", "alice", 1, "usd", usd()),
        open_account("a-eur", "bob", 2, "eur", eur()),
    ];
    let mut heads: Vec<(String, String)> = Vec::new();
    let mut time = 10;
    for index in 0..450 {
        let actor = ["alice", "bob", "carol"][index % 3];
        let transaction = format!("t{index}");
        let record_id = format!("r{index}");
        events.push(record(
            &record_id,
            actor,
            time,
            &transaction,
            "usd",
            1_000 + index as i64,
        ));
        heads.push((transaction, record_id));
        time += 1;
    }
    // Concurrent edits (two authors both based on the record), sequential
    // edits, and voids racing edits, spread over the same transactions.
    for (index, (transaction, record_id)) in heads.iter().enumerate() {
        match index % 4 {
            0 => {
                events.push(adjust(
                    &format!("ea{index}"),
                    "alice",
                    time,
                    transaction,
                    2_000,
                    record_id,
                ));
                events.push(adjust(
                    &format!("eb{index}"),
                    "bob",
                    time + 1,
                    transaction,
                    3_000,
                    record_id,
                ));
            }
            1 => {
                events.push(adjust(
                    &format!("ea{index}"),
                    "alice",
                    time,
                    transaction,
                    2_000,
                    record_id,
                ));
                events.push(adjust(
                    &format!("eb{index}"),
                    "bob",
                    time + 1,
                    transaction,
                    3_000,
                    &format!("ea{index}"),
                ));
            }
            2 => {
                events.push(void(
                    &format!("v{index}"),
                    "carol",
                    time,
                    transaction,
                    record_id,
                ));
                events.push(adjust(
                    &format!("e{index}"),
                    "bob",
                    time + 1,
                    transaction,
                    9_000,
                    record_id,
                ));
            }
            _ => {}
        }
        time += 2;
    }
    assert!(events.len() >= 1_000, "{}", events.len());

    let mut first = events.clone();
    let mut second = events.clone();
    shuffle(&mut first, 0xA11CE);
    shuffle(&mut second, 0xB0B);
    let first = fold_shared(usd(), first);
    let second = fold_shared(usd(), second);

    assert_eq!(first.canonical_bytes(), second.canonical_bytes());
    assert!(!first.conflicts.is_empty());
    assert!(!first.rejected.is_empty());
}

#[test]
fn a_multi_currency_shared_ledger_keeps_historical_balances_after_an_fx_change() {
    let eur_at = |rate_num: i64| FxRate::new(rate_num, 100, usd()).unwrap();
    let eur_expense = |id: &str, time: i64, transaction: &str, fx: FxRate| {
        shared(
            Event::new(
                id,
                "bob",
                time,
                0,
                EventKind::TransactionRecorded {
                    transaction_id: TransactionId::new(transaction),
                    account_id: AccountId::new("eur"),
                    kind: TransactionKind::Expense,
                    original: Money::new(10_000, eur()),
                    reporting_fx: fx,
                    title: transaction.to_owned(),
                    category_id: None,
                    recurring_id: None,
                },
            ),
            None,
        )
    };
    let open = open_account("a-eur", "bob", 1, "eur", eur());
    let before = fold_shared(
        usd(),
        vec![open.clone(), eur_expense("x1", 2, "hotel", eur_at(110))],
    );
    let after = fold_shared(
        usd(),
        vec![
            open,
            eur_expense("x1", 2, "hotel", eur_at(110)),
            // The rate moves; the new entry uses it, the old one must not.
            eur_expense("x2", 3, "taxi", eur_at(125)),
        ],
    );
    let hotel = TransactionId::new("hotel");
    assert_eq!(
        before.ledger.transactions[&hotel].reporting_minor,
        after.ledger.transactions[&hotel].reporting_minor
    );
    assert_eq!(after.ledger.transactions[&hotel].reporting_minor, 11_000);
    assert_eq!(after.ledger.reporting_balance_minor, -(11_000 + 12_500));
}

#[test]
fn shared_events_round_trip_through_the_wire_encoding() {
    let event = adjust("e1", "bob", 11, "dinner", 4_200, "r1");
    let bytes = encode_shared_event(&event);
    assert_eq!(decode_shared_event(&bytes), Some(event.clone()));
    assert_eq!(encode_shared_event(&event), bytes, "encoding is canonical");

    let without_base = record("r1", "alice", 2, "dinner", "joint", 4_000);
    assert_eq!(
        decode_shared_event(&encode_shared_event(&without_base)),
        Some(without_base)
    );

    assert_eq!(decode_shared_event(&bytes[..bytes.len() - 1]), None);
    assert_eq!(decode_shared_event(b"garbage"), None);
    let mut trailing = bytes;
    trailing.push(0);
    assert_eq!(decode_shared_event(&trailing), None);
}

#[test]
fn balances_are_unchanged_by_who_saw_what_when_nothing_conflicts() {
    // A plain ledger of independent expenses: no conflicts, no rejections.
    let events: Vec<_> = std::iter::once(open_account("a0", "alice", 1, "joint", usd()))
        .chain((0..50).map(|index| {
            record(
                &format!("r{index}"),
                ["alice", "bob"][index % 2],
                10 + index as i64,
                &format!("t{index}"),
                "joint",
                100,
            )
        }))
        .collect();
    let state = fold_shared(usd(), events.clone());
    assert_eq!(balance(events), -5_000);
    assert!(state.conflicts.is_empty() && state.rejected.is_empty());
}

#[test]
fn edit_heads_report_the_last_applied_event_per_field() {
    let state = fold_shared(
        usd(),
        vec![
            open_account("a0", "alice", 1, "joint", usd()),
            record("r1", "alice", 2, "dinner", "joint", 4_000),
            adjust("e1", "alice", 10, "dinner", 4_500, "r1"),
        ],
    );
    let dinner = TransactionId::new("dinner");
    assert_eq!(
        state.edit_head(&dinner, EditField::Amount),
        Some(&EventId::new("e1"))
    );
    assert_eq!(
        state.edit_head(&dinner, EditField::Category),
        Some(&EventId::new("r1"))
    );
    assert_eq!(
        state.edit_head(&TransactionId::new("missing"), EditField::Amount),
        None
    );
}
