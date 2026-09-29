use cash_core::{AccountId, Currency, Event, EventKind, FoldError, FxRate, Money, TransactionId, fold};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn eur() -> Currency {
    Currency::from_code("EUR").unwrap()
}

fn account_event(id: &str, account: &str, currency: Currency) -> Event {
    Event::new(
        id,
        "alice",
        0,
        0,
        EventKind::AccountOpened {
            account_id: AccountId::new(account),
            name: account.to_owned(),
            currency,
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn transfer_event(
    id: &str,
    time: i64,
    from: &str,
    to: &str,
    sent: Money,
    sent_fx: FxRate,
    received: Money,
    received_fx: FxRate,
) -> Event {
    Event::new(
        id,
        "alice",
        time,
        0,
        EventKind::TransferRecorded {
            transfer_id: TransactionId::new(id),
            from_account_id: AccountId::new(from),
            to_account_id: AccountId::new(to),
            sent,
            sent_reporting_fx: sent_fx,
            received,
            received_reporting_fx: received_fx,
            title: "Transfer".to_owned(),
        },
    )
}

#[test]
fn a_same_currency_transfer_moves_balance_without_changing_the_total() {
    let events = vec![
        account_event("checking", "checking", usd()),
        account_event("savings", "savings", usd()),
        transfer_event(
            "t1",
            1,
            "checking",
            "savings",
            Money::new(5000, usd()),
            FxRate::identity(usd()),
            Money::new(5000, usd()),
            FxRate::identity(usd()),
        ),
    ];

    let state = fold(usd(), events).unwrap();
    assert_eq!(state.accounts[&AccountId::new("checking")].native_balance_minor, -5000);
    assert_eq!(state.accounts[&AccountId::new("savings")].native_balance_minor, 5000);
    // Moving money between one's own accounts is not income or expense.
    assert_eq!(state.reporting_balance_minor, 0);
}

#[test]
fn a_cross_currency_transfer_keeps_its_conversion_spread_visible() {
    let events = vec![
        account_event("usd-account", "usd-account", usd()),
        account_event("eur-account", "eur-account", eur()),
        transfer_event(
            "t1",
            1,
            "usd-account",
            "eur-account",
            Money::new(10_00, usd()),
            FxRate::identity(usd()),
            // A conversion fee: only 9.00 EUR arrives for 10.00 USD sent.
            Money::new(9_00, eur()),
            FxRate::new(110, 100, usd()).unwrap(),
        ),
    ];

    let state = fold(usd(), events).unwrap();
    assert_eq!(
        state.accounts[&AccountId::new("usd-account")].native_balance_minor,
        -1000
    );
    assert_eq!(
        state.accounts[&AccountId::new("eur-account")].native_balance_minor,
        900
    );
    // 9.00 EUR at 1.10 reports as 9.90 USD received against 10.00 USD sent:
    // a 0.10 USD loss on the conversion, visible rather than hidden.
    assert_eq!(state.reporting_balance_minor, -10);
}

#[test]
fn a_transfer_to_the_same_account_is_rejected() {
    let events = vec![
        account_event("checking", "checking", usd()),
        transfer_event(
            "t1",
            1,
            "checking",
            "checking",
            Money::new(500, usd()),
            FxRate::identity(usd()),
            Money::new(500, usd()),
            FxRate::identity(usd()),
        ),
    ];

    assert!(matches!(
        fold(usd(), events),
        Err(FoldError::TransferToSameAccount(_))
    ));
}

#[test]
fn a_transfer_from_an_unknown_account_is_rejected() {
    let events = vec![
        account_event("savings", "savings", usd()),
        transfer_event(
            "t1",
            1,
            "checking",
            "savings",
            Money::new(500, usd()),
            FxRate::identity(usd()),
            Money::new(500, usd()),
            FxRate::identity(usd()),
        ),
    ];

    assert!(matches!(
        fold(usd(), events),
        Err(FoldError::UnknownAccount(_))
    ));
}

#[test]
fn a_transfer_whose_currency_does_not_match_the_account_is_rejected() {
    let events = vec![
        account_event("usd-account", "usd-account", usd()),
        account_event("eur-account", "eur-account", eur()),
        transfer_event(
            "t1",
            1,
            "usd-account",
            "eur-account",
            Money::new(500, usd()),
            FxRate::identity(usd()),
            // Wrong: the destination account is EUR, not USD.
            Money::new(500, usd()),
            FxRate::identity(usd()),
        ),
    ];

    assert!(matches!(
        fold(usd(), events),
        Err(FoldError::AccountCurrencyMismatch(_))
    ));
}

#[test]
fn a_duplicate_transfer_id_with_different_content_is_rejected() {
    let events = vec![
        account_event("checking", "checking", usd()),
        account_event("savings", "savings", usd()),
        transfer_event(
            "t1",
            1,
            "checking",
            "savings",
            Money::new(500, usd()),
            FxRate::identity(usd()),
            Money::new(500, usd()),
            FxRate::identity(usd()),
        ),
        transfer_event(
            "t1",
            1,
            "checking",
            "savings",
            Money::new(999, usd()),
            FxRate::identity(usd()),
            Money::new(999, usd()),
            FxRate::identity(usd()),
        ),
    ];

    assert!(fold(usd(), events).is_err());
}

#[test]
fn transfers_fold_identically_regardless_of_arrival_order() {
    let account_open = vec![
        account_event("checking", "checking", usd()),
        account_event("savings", "savings", usd()),
    ];
    let transfers = vec![
        transfer_event(
            "t1",
            1,
            "checking",
            "savings",
            Money::new(500, usd()),
            FxRate::identity(usd()),
            Money::new(500, usd()),
            FxRate::identity(usd()),
        ),
        transfer_event(
            "t2",
            2,
            "savings",
            "checking",
            Money::new(200, usd()),
            FxRate::identity(usd()),
            Money::new(200, usd()),
            FxRate::identity(usd()),
        ),
    ];

    let forward: Vec<Event> = account_open
        .iter()
        .cloned()
        .chain(transfers.iter().cloned())
        .collect();
    let backward: Vec<Event> = account_open
        .into_iter()
        .chain(transfers.into_iter().rev())
        .collect();

    let forward_state = fold(usd(), forward).unwrap();
    let backward_state = fold(usd(), backward).unwrap();
    assert_eq!(forward_state, backward_state);
    assert_eq!(
        forward_state.canonical_bytes(),
        backward_state.canonical_bytes()
    );
    assert_eq!(
        forward_state.accounts[&AccountId::new("checking")].native_balance_minor,
        -300
    );
    assert_eq!(
        forward_state.accounts[&AccountId::new("savings")].native_balance_minor,
        300
    );
}
