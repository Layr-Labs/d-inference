//! Load anonymized routing replay samples and score prediction accuracy.

use darkbloom_core::{score_replay, ReplaySample};

#[test]
fn scores_checked_in_fixture() {
    let raw = include_str!("../../../tests/routing-replay/samples.json");
    let samples: Vec<ReplaySample> = serde_json::from_str(raw).unwrap();
    let report = score_replay(&samples);
    assert_eq!(report.samples, 3);
    assert!(report.mean_abs_pct_error < 30.0);
    assert!(report.within_20pct > 0.0);
    assert!(report
        .intentional_differences
        .iter()
        .any(|d| d == "prepare_hedge_not_start_speculation"));
    // Serialize report so CI can artifact it later.
    let json = serde_json::to_string_pretty(&report).unwrap();
    assert!(json.contains("mean_abs_pct_error"));
}
