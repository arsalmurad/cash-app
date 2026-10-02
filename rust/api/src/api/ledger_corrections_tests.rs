use super::*;

#[test]
fn transfer_activity_uses_recorded_order_not_random_operation_ids() {
    let (ledger, mut log) = fixture("USD", "1", 1, 1);
    log.extend(
        add_account(&ledger, "other".into(), "Other".into(), "USD".into(), 3)
            .unwrap()
            .appended_frame,
    );
    for (id, title) in [("zzzz-old", "Older"), ("0000-new", "Newest")] {
        log.extend(
            record_transfer(
                &ledger,
                id.into(),
                "cash".into(),
                "other".into(),
                "1".into(),
                "USD".into(),
                1,
                1,
                "1".into(),
                "USD".into(),
                1,
                1,
                title.into(),
                4,
            )
            .unwrap()
            .appended_frame,
        );
    }
    let restarted = load_personal_ledger("device".into(), "USD".into(), log).unwrap();
    assert_eq!(
        get_overview(&restarted)
            .unwrap()
            .transfers
            .iter()
            .map(|t| t.id.as_str())
            .collect::<Vec<_>>(),
        ["0000-new", "zzzz-old"]
    );
}

#[test]
fn recent_activity_uses_recorded_order_not_random_operation_ids() {
    let (ledger, mut log) = fixture("USD", "1", 1, 1);
    log.extend(
        record_transaction(
            &ledger,
            "zzzz-old".into(),
            "cash".into(),
            EntryKind::Expense,
            "2".into(),
            "USD".into(),
            1,
            1,
            "Older".into(),
            None,
            None,
            3,
        )
        .unwrap()
        .appended_frame,
    );
    log.extend(
        record_transaction(
            &ledger,
            "0000-new".into(),
            "cash".into(),
            EntryKind::Expense,
            "3".into(),
            "USD".into(),
            1,
            1,
            "Newest".into(),
            None,
            None,
            3,
        )
        .unwrap()
        .appended_frame,
    );
    let expected = vec!["0000-new", "zzzz-old", "expense"];
    assert_eq!(
        get_overview(&ledger)
            .unwrap()
            .transactions
            .iter()
            .map(|t| t.id.as_str())
            .collect::<Vec<_>>(),
        expected
    );
    log.extend(
        adjust_transaction_amount(&ledger, "expense".into(), "1".into(), "4".into(), 4)
            .unwrap()
            .appended_frame,
    );
    let restarted = load_personal_ledger("device".into(), "USD".into(), log).unwrap();
    assert_eq!(
        get_overview(&restarted)
            .unwrap()
            .transactions
            .iter()
            .map(|t| t.id.as_str())
            .collect::<Vec<_>>(),
        expected
    );
}

#[test]
fn overflowing_correction_does_not_commit_and_title_suggestions_follow_category_changes() {
    let (ledger, _) = fixture("JPY", "100", 2, 1);
    let before = get_overview(&ledger).unwrap();
    let clock = lock(&ledger).unwrap().last_timestamp;
    assert!(
        adjust_transaction_amount(
            &ledger,
            "expense".into(),
            "100".into(),
            i64::MAX.to_string(),
            i64::MAX
        )
        .is_err()
    );
    assert_eq!(get_overview(&ledger).unwrap(), before);
    assert_eq!(lock(&ledger).unwrap().last_timestamp, clock);
    assign_transaction_category(
        &ledger,
        "expense".into(),
        Some("food".into()),
        Some("travel".into()),
        3,
    )
    .unwrap();
    assert_eq!(
        suggest_category_for_title(&ledger, " lunch ".into())
            .unwrap()
            .as_deref(),
        Some("travel")
    );
    void_transaction(
        &ledger,
        "expense".into(),
        "100".into(),
        Some("travel".into()),
        4,
    )
    .unwrap();
    assert_eq!(
        suggest_category_for_title(&ledger, "Lunch".into()).unwrap(),
        None
    );
}

fn fixture(
    currency: &str,
    amount: &str,
    numerator: i64,
    denominator: i64,
) -> (PersonalLedger, Vec<u8>) {
    let ledger = load_personal_ledger("device".into(), "USD".into(), vec![]).unwrap();
    let mut log = add_account(&ledger, "cash".into(), "Cash".into(), currency.into(), 1)
        .unwrap()
        .appended_frame;
    log.extend(
        record_transaction(
            &ledger,
            "expense".into(),
            "cash".into(),
            EntryKind::Expense,
            amount.into(),
            currency.into(),
            numerator,
            denominator,
            "Lunch".into(),
            Some("food".into()),
            None,
            2,
        )
        .unwrap()
        .appended_frame,
    );
    (ledger, log)
}

#[test]
fn corrections_keep_frozen_fx_creation_time_and_all_history_after_restart() {
    let (ledger, mut log) = fixture("EUR", "80.00", 87, 80);
    let original_log = log.clone();
    log.extend(
        adjust_transaction_amount(&ledger, "expense".into(), "80.00".into(), "85.00".into(), 3)
            .unwrap()
            .appended_frame,
    );
    assert_eq!(get_overview(&ledger).unwrap().balance_label, "USD -92.44");
    assert_eq!(
        folded_state(&ledger).unwrap().transactions[&TransactionId::new("expense")]
            .recorded_at_millis,
        2
    );
    assert!(
        adjust_transaction_amount(&ledger, "expense".into(), "80.00".into(), "90.00".into(), 4)
            .is_err()
    );
    log.extend(
        assign_transaction_category(
            &ledger,
            "expense".into(),
            Some("food".into()),
            Some("travel".into()),
            4,
        )
        .unwrap()
        .appended_frame,
    );
    assert!(
        void_transaction(
            &ledger,
            "expense".into(),
            "85.00".into(),
            Some("food".into()),
            5
        )
        .is_err()
    );
    log.extend(
        void_transaction(
            &ledger,
            "expense".into(),
            "85.00".into(),
            Some("travel".into()),
            5,
        )
        .unwrap()
        .appended_frame,
    );
    assert_eq!(&log[..original_log.len()], original_log);
    let restarted = load_personal_ledger("device".into(), "USD".into(), log).unwrap();
    let overview = get_overview(&restarted).unwrap();
    assert_eq!(overview.balance_label, "USD 0.00");
    assert_eq!(overview.accounts[0].balance_label, "EUR 0.00");
    assert!(overview.transactions[0].voided);
    let history = transaction_history(&restarted, "expense".into()).unwrap();
    assert_eq!(history.len(), 4);
    assert_eq!(history[0].action, "Recorded");
    assert_eq!(history[1].amount_label.as_deref(), Some("EUR 85.00"));
    assert_eq!(
        history[1].reporting_amount_label.as_deref(),
        Some("USD 92.44")
    );
    assert_eq!(history[2].category_id.as_deref(), Some("travel"));
    assert_eq!(history[3].action, "Removed from balances");
    assert!(
        adjust_transaction_amount(
            &restarted,
            "expense".into(),
            "85.00".into(),
            "90.00".into(),
            6
        )
        .is_err()
    );
    assert!(
        assign_transaction_category(&restarted, "expense".into(), Some("travel".into()), None, 6)
            .is_err()
    );
    assert!(
        void_transaction(
            &restarted,
            "expense".into(),
            "85.00".into(),
            Some("travel".into()),
            6
        )
        .is_err()
    );
}

#[test]
fn rejected_corrections_leave_events_and_clock_unchanged() {
    let (ledger, _) = fixture("JPY", "100", 1, 1);
    let before = get_overview(&ledger).unwrap();
    let clock = lock(&ledger).unwrap().last_timestamp;
    for amount in ["1.5", "0", "-1", "9223372036854775808"] {
        assert!(
            adjust_transaction_amount(
                &ledger,
                "expense".into(),
                "100".into(),
                amount.into(),
                i64::MAX
            )
            .is_err()
        );
    }
    assert!(
        adjust_transaction_amount(
            &ledger,
            "unknown".into(),
            "100".into(),
            "200".into(),
            i64::MAX
        )
        .is_err()
    );
    assert!(
        assign_transaction_category(
            &ledger,
            "expense".into(),
            None,
            Some("travel".into()),
            i64::MAX
        )
        .is_err()
    );
    assert_eq!(get_overview(&ledger).unwrap(), before);
    assert_eq!(lock(&ledger).unwrap().last_timestamp, clock);
    let corrected =
        adjust_transaction_amount(&ledger, "expense".into(), "100".into(), "200".into(), 3)
            .unwrap();
    assert_eq!(corrected.overview.transactions[0].amount_label, "JPY 200");
    assert_eq!(decode_event_log(&corrected.appended_frame).events.len(), 1);
}
