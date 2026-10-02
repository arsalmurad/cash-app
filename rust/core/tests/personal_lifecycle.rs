use cash_core::*;

macro_rules! lifecycle_tests {
    ($module:ident, $make:expr, $fold:ident, $encode:ident, $decode:ident, $map:ident, $id:expr) => {
        mod $module {
            use super::*;

            #[test]
            fn removal_survives_replay_late_arrival_and_restart() {
                let original = $make;
                let legacy_frame = $encode(&original);
                let decoded = $decode(&legacy_frame);
                assert_eq!(decoded.trailing_garbage_bytes, 0);
                assert_eq!(decoded.upserts, vec![original.clone()]);
                assert!(!decoded.upserts[0].deleted);

                let mut removed = original.clone();
                removed.id = EventId::new("remove");
                removed.timestamp = HybridTimestamp::new(20, 0);
                removed.deleted = true;
                let mut bytes = legacy_frame;
                bytes.extend($encode(&removed));
                let decoded = $decode(&bytes);
                assert_eq!(decoded.trailing_garbage_bytes, 0);
                let forward = $fold(decoded.upserts);
                let backward = $fold([removed.clone(), original.clone(), removed.clone()]);
                assert_eq!(forward, backward);
                assert!(forward.$map[&$id].deleted);

                let mut restored = original.clone();
                restored.id = EventId::new("restore");
                restored.timestamp = HybridTimestamp::new(30, 0);
                let restored_state = $fold([restored, removed, original]);
                assert!(!restored_state.$map[&$id].deleted);
            }

            #[test]
            fn event_id_breaks_equal_actor_clock_ties_in_both_orders() {
                let mut kept = $make;
                kept.id = EventId::new("a");
                let mut removed = kept.clone();
                removed.id = EventId::new("z");
                removed.deleted = true;
                let one = $fold([kept.clone(), removed.clone()]);
                let two = $fold([removed, kept]);
                assert_eq!(one, two);
                assert!(one.$map[&$id].deleted);
            }
        }
    };
}

lifecycle_tests!(
    budgets,
    BudgetUpsert::new(
        "create",
        "alice",
        10,
        0,
        BudgetId::new("food"),
        "Food",
        None,
        1000,
        BudgetPeriod::Monthly
    ),
    fold_budgets,
    encode_budget_frame,
    decode_budget_log,
    budgets,
    BudgetId::new("food")
);
lifecycle_tests!(
    goals,
    GoalUpsert::new(
        "create",
        "alice",
        10,
        0,
        GoalId::new("holiday"),
        "Holiday",
        GoalKind::Save,
        1000,
        Some("cash".into()),
        None,
        None
    ),
    fold_goals,
    encode_goal_frame,
    decode_goal_log,
    goals,
    GoalId::new("holiday")
);
lifecycle_tests!(
    recurring,
    RecurringUpsert::new(
        "create",
        "alice",
        10,
        0,
        RecurringId::new("rent"),
        "Rent",
        RecurringKind::Expense,
        1000,
        "cash",
        None,
        RecurringFrequency::Monthly,
        0
    ),
    fold_recurring,
    encode_recurring_frame,
    decode_recurring_log,
    rules,
    RecurringId::new("rent")
);
