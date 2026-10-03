use super::*;

#[test]
fn read_window_finishes_the_first_tail_and_preserves_later_entries_for_next_read() {
    let mut window = ReadWindow::new(0);
    assert!(
        !window
            .accept(
                checked_page(
                    &json!({"entries": [{"seq": 1, "blob": "YQ=="}], "tail": 2, "more": true}),
                    0,
                    0
                )
                .unwrap()
            )
            .unwrap()
    );
    assert!(window.accept(checked_page(&json!({"entries": [{"seq": 2, "blob": "Yg=="}, {"seq": 3, "blob": "Yw=="}], "tail": 3, "more": false}), 1, 2).unwrap()).unwrap());
    assert_eq!(window.entries, vec![(1, b"a".to_vec()), (2, b"b".to_vec())]);
    let mut next = ReadWindow::new(2);
    assert!(
        next.accept(
            checked_page(
                &json!({"entries": [{"seq": 3, "blob": "Yw=="}], "tail": 3, "more": false}),
                2,
                2
            )
            .unwrap()
        )
        .unwrap()
    );
    assert_eq!(next.entries, vec![(3, b"c".to_vec())]);
}

#[test]
fn read_window_refuses_entry_and_aggregate_byte_overflow() {
    let mut too_many = ReadWindow::new(0);
    assert!(
        too_many
            .accept(CheckedPage {
                entries: vec![],
                tail: 10_001,
                more: true
            })
            .is_err()
    );
    let mut window = ReadWindow::new(0);
    // Synthetic prior budget isolates exact overflow without allocating 64 MiB.
    window.bytes = 64 * 1024 * 1024 - 1;
    assert!(
        window
            .accept(CheckedPage {
                entries: vec![(1, vec![1])],
                tail: 2,
                more: true
            })
            .is_ok()
    );
    assert!(
        window
            .accept(CheckedPage {
                entries: vec![(2, vec![2])],
                tail: 2,
                more: false
            })
            .is_err()
    );
}

#[test]
fn json_response_bytes_are_bounded_before_parsing() {
    let exact = vec![b' '; MAX_RESPONSE_BYTES];
    let mut valid = exact.clone();
    valid[0] = b'0';
    assert_eq!(bounded_body(std::io::Cursor::new(valid)).unwrap(), json!(0));
    let oversized = vec![b' '; MAX_RESPONSE_BYTES + 1];
    assert!(bounded_body(std::io::Cursor::new(oversized)).is_err());
}

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
