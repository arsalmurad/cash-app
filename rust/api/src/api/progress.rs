/// Presentation only: money remains i64 minor units. Use a wider intermediate
/// so a valid balance/target ratio does not fail during multiplication by 100.
/// Ratios above the bridge's i64 range saturate; the UI displays a lower bound
/// for huge percentages rather than presenting that saturation as exact.
pub(super) fn percentage(progress: i64, target: i64) -> i64 {
    if target <= 0 {
        return 0;
    }
    let result = i128::from(progress.max(0)) * 100 / i128::from(target);
    result.min(i128::from(i64::MAX)) as i64
}

#[cfg(test)]
mod tests {
    use super::percentage;

    #[test]
    fn percentage_is_integer_truncated_nonnegative_and_bounded() {
        assert_eq!(percentage(1, 3), 33);
        assert_eq!(percentage(2, 3), 66);
        assert_eq!(percentage(3, 2), 150);
        assert_eq!(percentage(i64::MAX, i64::MAX), 100);
        assert_eq!(percentage(i64::MAX, 100), i64::MAX);
        assert_eq!(percentage(i64::MAX, 1), i64::MAX);
        assert_eq!(percentage(i64::MIN, 1), 0);
        assert_eq!(percentage(1, 0), 0);
        assert_eq!(percentage(1, -1), 0);
    }
}
