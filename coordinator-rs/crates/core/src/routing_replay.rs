//! Routing replay harness (plan §21 M1 / §22).
//!
//! Scores first-content prediction accuracy against recorded actuals.
//! Fixtures contain no prompt content.

use crate::TtftCalibrator;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplaySample {
    pub model: String,
    pub hardware_class: String,
    pub predicted_ttft_ms: f64,
    pub actual_ttft_ms: f64,
    pub selected_provider: String,
    pub alternate_providers: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplayReport {
    pub samples: usize,
    pub mean_abs_pct_error: f64,
    pub median_ratio: f64,
    pub within_20pct: f64,
    pub intentional_differences: Vec<String>,
}

pub fn score_replay(samples: &[ReplaySample]) -> ReplayReport {
    let mut cal = TtftCalibrator::default();
    for s in samples {
        cal.record(&s.model, s.predicted_ttft_ms, s.actual_ttft_ms);
    }
    let mut ape_sum = 0.0;
    let mut ratios = Vec::new();
    let mut within = 0usize;
    for s in samples {
        let calibrated = cal.calibrate(&s.model, s.predicted_ttft_ms);
        let ape = ((calibrated - s.actual_ttft_ms).abs() / s.actual_ttft_ms.max(1.0)) * 100.0;
        ape_sum += ape;
        let ratio = s.actual_ttft_ms / s.predicted_ttft_ms.max(1.0);
        ratios.push(ratio);
        if ape <= 20.0 {
            within += 1;
        }
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median_ratio = if ratios.is_empty() {
        1.0
    } else if ratios.len() % 2 == 0 {
        (ratios[ratios.len() / 2 - 1] + ratios[ratios.len() / 2]) / 2.0
    } else {
        ratios[ratios.len() / 2]
    };
    let n = samples.len().max(1) as f64;
    ReplayReport {
        samples: samples.len(),
        mean_abs_pct_error: ape_sum / n,
        median_ratio,
        within_20pct: within as f64 / n,
        intentional_differences: vec![
            "no_120s_queue".into(),
            "prepare_hedge_not_start_speculation".into(),
            "one_fleet_admit_not_preflight_plus_reserve".into(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scores_fixture_and_lists_intentional_diffs() {
        let samples = vec![
            ReplaySample {
                model: "m".into(),
                hardware_class: "m2-max".into(),
                predicted_ttft_ms: 200.0,
                actual_ttft_ms: 180.0,
                selected_provider: "p1".into(),
                alternate_providers: vec!["p2".into()],
            },
            ReplaySample {
                model: "m".into(),
                hardware_class: "m2-max".into(),
                predicted_ttft_ms: 200.0,
                actual_ttft_ms: 220.0,
                selected_provider: "p1".into(),
                alternate_providers: vec![],
            },
        ];
        let report = score_replay(&samples);
        assert_eq!(report.samples, 2);
        assert!(report.mean_abs_pct_error < 50.0);
        assert!(report.intentional_differences.contains(&"no_120s_queue".into()));
    }
}
