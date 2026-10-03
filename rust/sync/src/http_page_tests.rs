use super::*;

#[test]
fn checked_pages_refuse_gaps_rollback_stalls_and_false_completion() {
    let invalid = [
        json!({"entries": [], "tail": 1, "more": true}),
        json!({"entries": [], "tail": 1, "more": false}),
        json!({"entries": [], "tail": -1, "more": false}),
        json!({"entries": [], "tail": 0}),
        json!({"entries": [], "tail": 0, "more": "false"}),
        json!({"entries": [{"seq": 2, "blob": "YQ=="}], "tail": 2, "more": false}),
        json!({"entries": [{"seq": 1, "blob": "YQ=="}, {"seq": 1, "blob": "YQ=="}], "tail": 1, "more": false}),
        json!({"entries": [{"seq": 1, "blob": "YQ=="}], "tail": 0, "more": false}),
        json!({"entries": [{"seq": 1, "blob": "YQ=="}], "tail": 2, "more": false}),
        json!({"entries": [{"seq": 1, "blob": "YQ=="}], "tail": 1, "more": true}),
        json!({"entries": [{"seq": 1, "blob": ""}], "tail": 1, "more": false}),
    ];
    for page in invalid {
        assert!(checked_page(&page, 0, 0).is_err(), "accepted {page}");
    }
    assert!(
        checked_page(
            &json!({"entries": [{"seq": 2, "blob": "YQ=="}], "tail": 2, "more": false}),
            1,
            3
        )
        .is_err()
    );
    assert!(
        checked_page(
            &json!({"entries": [{"seq": 3, "blob": "YQ=="}], "tail": 3, "more": false}),
            1,
            3
        )
        .is_err()
    );
}

#[test]
fn checked_pages_accept_empty_completion_and_concurrent_tail_growth() {
    let empty = checked_page(&json!({"entries": [], "tail": 3, "more": false}), 3, 3).unwrap();
    assert!(empty.entries.is_empty());
    assert!(!empty.more);
    let page = checked_page(
        &json!({"entries": [{"seq": 2, "blob": "Yg=="}], "tail": 4, "more": true}),
        1,
        3,
    )
    .unwrap();
    assert_eq!(page.entries, vec![(2, b"b".to_vec())]);
    assert_eq!(page.tail, 4);
    assert!(page.more);
}
