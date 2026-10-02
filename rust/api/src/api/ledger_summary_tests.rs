use super::*;
use crate::api::shared::*;

#[test]
fn preview_is_read_only_target_bound_frozen_and_published_only_once() {
    let ledger = load_personal_ledger("private-actor".into(), "USD".into(), vec![]).unwrap();
    add_account(
        &ledger,
        "secret-account".into(),
        "Secret account".into(),
        "EUR".into(),
        1,
    )
    .unwrap();
    record_transaction(
        &ledger,
        "secret-entry".into(),
        "secret-account".into(),
        EntryKind::Expense,
        "80".into(),
        "EUR".into(),
        87,
        80,
        "Secret title".into(),
        Some("secret-category".into()),
        None,
        10,
    )
    .unwrap();
    let household = household_new("household-device".into(), "USD".into()).unwrap();
    let group = household_found(&household).unwrap();
    let personal_before = get_overview(&ledger).unwrap();
    let shared_before = household_export(&household).unwrap();
    assert!(prepare_summary(&ledger, group.clone(), 10, 20, false, false).is_err());
    let draft = prepare_summary(&ledger, group.clone(), 10, 20, false, true).unwrap();
    let preview = summary_preview(&draft);
    assert_eq!(preview.income_label, None);
    assert_eq!(preview.expenses_label.as_deref(), Some("USD 87.00"));
    assert_eq!(preview.group_id, group);
    assert_eq!(get_overview(&ledger).unwrap(), personal_before);
    assert_eq!(household_export(&household).unwrap(), shared_before);
    adjust_transaction_amount(&ledger, "secret-entry".into(), "80".into(), "85".into(), 30)
        .unwrap();
    let other = household_new("another-household".into(), "USD".into()).unwrap();
    household_found(&other).unwrap();
    assert!(household_publish_summary(&other, &draft, 40).is_err());
    household_publish_summary(&household, &draft, 40).unwrap();
    assert!(household_publish_summary(&household, &draft, 41).is_err());
    let published = household_summaries(&household).unwrap();
    assert_eq!(published.len(), 1);
    assert_eq!(
        published[0].preview.expenses_label.as_deref(),
        Some("USD 87.00")
    );
    assert_eq!(published[0].preview.income_label, None);
    let shared = household_overview(&household).unwrap();
    assert_eq!(shared.balance_label, "USD 0.00");
    assert!(shared.transactions.is_empty());
    assert_eq!(shared.pending_count, 1);
    let restarted = household_restore(household_export(&household).unwrap()).unwrap();
    assert_eq!(household_summaries(&restarted).unwrap(), published);
    let bytes = household_export(&household).unwrap();
    for secret in [
        "private-actor",
        "secret-account",
        "secret-entry",
        "Secret title",
        "secret-category",
    ] {
        assert!(
            !bytes
                .windows(secret.len())
                .any(|value| value == secret.as_bytes())
        );
    }
}
