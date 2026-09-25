use cash_core::{
    AccountId, Currency, Event, EventKind, FxRate, Money, Snapshot, SnapshotError, TransactionId,
    TransactionKind, fold,
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

fn shuffle(values: &mut [Event], mut state: u64) {
    for index in (1..values.len()).rev() {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        values.swap(index, (state as usize) % (index + 1));
    }
}

#[test]
fn one_thousand_events_fold_identically_in_different_arrival_orders() {
    let mut first = thousand_events();
    let mut second = first.clone();
    shuffle(&mut first, 0xA11CE);
    shuffle(&mut second, 0xB0B);

    let first_state = fold(usd(), first).unwrap();
    let second_state = fold(usd(), second).unwrap();

    assert_eq!(first_state, second_state);
    assert_eq!(
        first_state.canonical_bytes(),
        second_state.canonical_bytes()
    );
}

#[test]
fn frozen_fx_keeps_historical_balances_stable_after_rate_changes() {
    let events = vec![
        account_event("account", "alice", 0, "travel", eur()),
        transaction_event(
            1,
            "alice",
            "travel",
            10_00,
            eur(),
            FxRate::new(110, 100, usd()).unwrap(),
        ),
        transaction_event(
            2,
            "alice",
            "travel",
            10_00,
            eur(),
            FxRate::new(125, 100, usd()).unwrap(),
        ),
    ];

    let state = fold(usd(), events).unwrap();
    assert_eq!(
        state.transactions[&TransactionId::new("transaction-0001")].reporting_minor,
        1100
    );
    assert_eq!(
        state.transactions[&TransactionId::new("transaction-0002")].reporting_minor,
        1250
    );
    assert_eq!(state.reporting_balance_minor, -2350);
}

#[test]
fn zero_decimal_currency_round_trips_without_drift() {
    let jpy = Currency::from_code("JPY").unwrap();
    let events = vec![
        account_event("account", "alice", 0, "cash", jpy.clone()),
        transaction_event(
            1,
            "alice",
            "cash",
            12_345,
            jpy.clone(),
            FxRate::identity(jpy.clone()),
        ),
    ];

    let state = fold(jpy.clone(), events).unwrap();
    let transaction = &state.transactions[&TransactionId::new("transaction-0001")];
    assert_eq!(transaction.original.minor_units, 12_345);
    assert_eq!(transaction.original.currency.exponent(), 0);
    assert_eq!(
        jpy.format_minor_units(transaction.original.minor_units),
        "JPY 12345"
    );
    assert_eq!(state.reporting_balance_minor, -12_345);
}

#[test]
fn snapshot_at_five_hundred_matches_a_full_fold() {
    let events = thousand_events();
    let full = fold(usd(), events.clone()).unwrap();
    let snapshot = Snapshot::from_events(usd(), events[..500].to_vec()).unwrap();
    let resumed = snapshot.fold_forward(events[500..].to_vec()).unwrap();

    assert_eq!(resumed.state, full);
    assert_eq!(resumed.state.canonical_bytes(), full.canonical_bytes());
    assert_eq!(resumed.causal_frontier.len(), 2);
}

#[test]
fn a_late_event_invalidates_instead_of_corrupting_a_snapshot() {
    let events = thousand_events();
    let snapshot = Snapshot::from_events(usd(), events[..500].to_vec()).unwrap();
    let late = Event::new(
        "late-but-unique",
        "late-peer",
        42,
        0,
        EventKind::TransactionRecorded {
            transaction_id: TransactionId::new("late-transaction"),
            account_id: AccountId::new("usd-account"),
            kind: TransactionKind::Expense,
            original: Money::new(99, usd()),
            reporting_fx: FxRate::identity(usd()),
            title: "Late arrival".to_owned(),
            category_id: None,
        },
    );

    assert!(matches!(
        snapshot.fold_forward([late]),
        Err(SnapshotError::LateEventInvalidatesSnapshot(_))
    ));
}

#[test]
fn duplicate_event_ids_are_idempotent_but_conflicts_are_rejected() {
    let account = account_event("same-id", "alice", 0, "cash", usd());
    let state = fold(usd(), [account.clone(), account]).unwrap();
    assert_eq!(state.accounts.len(), 1);

    let conflicting = account_event("same-id", "alice", 0, "other", usd());
    assert!(
        fold(
            usd(),
            [
                account_event("same-id", "alice", 0, "cash", usd()),
                conflicting
            ]
        )
        .is_err()
    );
}
