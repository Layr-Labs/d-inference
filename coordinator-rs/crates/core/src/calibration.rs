//! Online first-content prediction calibration (plan §11.4).
//!
//! Maintains a windowed median of actual/predicted ratios per model and
//! applies a clamped multiplicative correction.

use std::collections::{HashMap, VecDeque};

const WINDOW: usize = 64;
const MIN_RATIO: f64 = 0.5;
const MAX_RATIO: f64 = 2.0;
const DEFAULT_RATIO: f64 = 1.0;

#[derive(Debug, Default, Clone)]
pub struct TtftCalibrator {
    /// model_id -> recent actual/predicted ratios
    windows: HashMap<String, VecDeque<f64>>,
}

impl TtftCalibrator {
    pub fn record(&mut self, model_id: &str, predicted_ms: f64, actual_ms: f64) {
        if predicted_ms <= 0.0 || actual_ms <= 0.0 {
            return;
        }
        let ratio = (actual_ms / predicted_ms).clamp(MIN_RATIO, MAX_RATIO);
        let w = self.windows.entry(model_id.to_string()).or_default();
        w.push_back(ratio);
        while w.len() > WINDOW {
            w.pop_front();
        }
    }

    pub fn correction(&self, model_id: &str) -> f64 {
        let Some(w) = self.windows.get(model_id) else {
            return DEFAULT_RATIO;
        };
        if w.is_empty() {
            return DEFAULT_RATIO;
        }
        let mut v: Vec<f64> = w.iter().copied().collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        // Fix Equal capitalization below via rewrite
        let mid = v.len() / 2;
        if v.len() % 2 == 0 {
            (v[mid - 1] + v[mid]) / 2.0
        } else {
            v[mid]
        }
    }

    pub fn calibrate(&self, model_id: &str, predicted_ms: f64) -> f64 {
        predicted_ms * self.correction(model_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn median_correction_clamped() {
        let mut c = TtftCalibrator::default();
        // Predicted 100, actual 200 → ratio 2.0
        for _ in 0..10 {
            c.record("m", 100.0, 200.0);
        }
        assert!((c.correction("m") - 2.0).abs() < 1e-9);
        assert!((c.calibrate("m", 50.0) - 100.0).abs() < 1e-9);
        // Extreme actual would clamp
        c.record("m", 100.0, 1000.0);
        assert!(c.correction("m") <= MAX_RATIO);
    }
}
