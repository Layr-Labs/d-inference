//! Online first-content prediction calibration (plan section 11.4).
//!
//! Maintains a windowed median of `actual / predicted` first-content latency
//! per (model, hardware class) and applies it as a clamped multiplicative
//! correction. Uncalibrated predictions ran 1.9-2.8x high in production and
//! produced ~883k spurious 429s before the Go coordinator gained the same
//! correction; the clamp (default [0.2, 1.5]) bounds how far one window can
//! push routing in either direction.
//!
//! Pure and fixed-size: one ring buffer per key, O(1) memory, no floats —
//! ratios are per-mille fixed point.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ids::{HardwareClass, ModelId};
use crate::time::DurationMs;

/// Fixed-point ratio in per-mille: 1000 == 1.0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RatioPerMille(u32);

impl RatioPerMille {
    pub const UNIT: Self = Self(1000);

    #[must_use]
    pub const fn new(per_mille: u32) -> Self {
        Self(per_mille)
    }

    #[must_use]
    pub const fn get(self) -> u32 {
        self.0
    }

    /// `duration * self`, rounded down; saturates at `u64::MAX` (a latency
    /// estimate, never money).
    #[must_use]
    pub fn apply_to(self, duration: DurationMs) -> DurationMs {
        let scaled = u128::from(duration.get()) * u128::from(self.0) / 1000u128;
        DurationMs::new(u64::try_from(scaled).unwrap_or(u64::MAX))
    }

    #[must_use]
    pub fn clamp(self, min: Self, max: Self) -> Self {
        Self(self.0.clamp(min.0, max.0))
    }
}

/// Hard upper bound on the configurable window so memory per key is a
/// compile-time constant.
pub const MAX_WINDOW: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CalibrationConfig {
    /// Samples per key; values above [`MAX_WINDOW`] are truncated at
    /// construction, so the ring buffer never grows.
    pub window: usize,
    /// Correction clamp floor (default 0.2).
    pub clamp_min: RatioPerMille,
    /// Correction clamp ceiling (default 1.5).
    pub clamp_max: RatioPerMille,
    /// Below this many samples the correction stays at 1.0: a near-empty
    /// window must not swing routing.
    pub min_samples: usize,
}

impl Default for CalibrationConfig {
    fn default() -> Self {
        Self {
            window: 64,
            clamp_min: RatioPerMille::new(200),
            clamp_max: RatioPerMille::new(1500),
            min_samples: 8,
        }
    }
}

impl CalibrationConfig {
    fn effective_window(&self) -> usize {
        self.window.clamp(1, MAX_WINDOW)
    }
}

/// Ring buffer of observed `actual / predicted` ratios for one
/// (model, hardware class) key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalibrationWindow {
    samples: [RatioPerMille; MAX_WINDOW],
    len: usize,
    next: usize,
}

impl Default for CalibrationWindow {
    fn default() -> Self {
        Self {
            samples: [RatioPerMille::UNIT; MAX_WINDOW],
            len: 0,
            next: 0,
        }
    }
}

impl CalibrationWindow {
    /// Record one completed prediction. Zero predictions carry no ratio
    /// information and are ignored; zero actuals record the clamp floor
    /// equivalent (ratio 0, clamped on read).
    pub fn observe(
        &mut self,
        actual: DurationMs,
        predicted: DurationMs,
        config: &CalibrationConfig,
    ) {
        if predicted.is_zero() {
            return;
        }
        let ratio = u128::from(actual.get()) * 1000u128 / u128::from(predicted.get());
        let ratio = RatioPerMille::new(u32::try_from(ratio).unwrap_or(u32::MAX));
        let window = config.effective_window();
        if self.next >= window {
            self.next = 0;
        }
        self.samples[self.next] = ratio;
        self.next = (self.next + 1) % window;
        self.len = (self.len + 1).min(window);
    }

    /// The clamped multiplicative correction: the windowed median when at
    /// least `min_samples` are present, otherwise exactly 1.0.
    ///
    /// The returned value is always within `[clamp_min, clamp_max]` — the
    /// clamp also bounds the unit fallback, so a config with a clamp range
    /// excluding 1.0 still yields an in-range correction.
    #[must_use]
    pub fn correction(&self, config: &CalibrationConfig) -> RatioPerMille {
        let raw = if self.len < config.min_samples.max(1) {
            RatioPerMille::UNIT
        } else {
            let mut sorted = [RatioPerMille::UNIT; MAX_WINDOW];
            sorted[..self.len].copy_from_slice(&self.samples[..self.len]);
            sorted[..self.len].sort_unstable();
            sorted[self.len / 2]
        };
        raw.clamp(config.clamp_min, config.clamp_max)
    }

    #[must_use]
    pub fn sample_count(&self) -> usize {
        self.len
    }
}

/// Calibration key: plan section 11.4 calibrates per model and hardware
/// class, not per provider.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CalibrationKey {
    pub model: ModelId,
    pub hardware_class: HardwareClass,
}

/// All calibration windows, keyed by (model, hardware class). Key cardinality
/// is bounded by catalog size times hardware classes.
#[derive(Debug, Clone, Default)]
pub struct CalibrationTable {
    windows: BTreeMap<CalibrationKey, CalibrationWindow>,
}

impl CalibrationTable {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(
        &mut self,
        key: CalibrationKey,
        actual: DurationMs,
        predicted: DurationMs,
        config: &CalibrationConfig,
    ) {
        self.windows
            .entry(key)
            .or_default()
            .observe(actual, predicted, config);
    }

    /// Correction for a key; exactly 1.0 (clamped) for never-observed keys.
    #[must_use]
    pub fn correction(&self, key: &CalibrationKey, config: &CalibrationConfig) -> RatioPerMille {
        self.windows.get(key).map_or_else(
            || RatioPerMille::UNIT.clamp(config.clamp_min, config.clamp_max),
            |w| w.correction(config),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn median_corrects_overprediction() {
        let config = CalibrationConfig::default();
        let mut window = CalibrationWindow::default();
        // Predictions consistently 2x too high => ratio 0.5.
        for _ in 0..16 {
            window.observe(DurationMs::new(500), DurationMs::new(1000), &config);
        }
        assert_eq!(window.correction(&config), RatioPerMille::new(500));
        let corrected = window.correction(&config).apply_to(DurationMs::new(2000));
        assert_eq!(corrected, DurationMs::new(1000));
    }

    #[test]
    fn insufficient_samples_stay_unit() {
        let config = CalibrationConfig::default();
        let mut window = CalibrationWindow::default();
        for _ in 0..(config.min_samples - 1) {
            window.observe(DurationMs::new(1), DurationMs::new(1000), &config);
        }
        assert_eq!(window.correction(&config), RatioPerMille::UNIT);
    }

    #[test]
    fn extreme_ratios_clamp() {
        let config = CalibrationConfig::default();
        let mut window = CalibrationWindow::default();
        for _ in 0..16 {
            window.observe(DurationMs::new(100_000), DurationMs::new(10), &config);
        }
        assert_eq!(window.correction(&config), config.clamp_max);

        let mut low = CalibrationWindow::default();
        for _ in 0..16 {
            low.observe(DurationMs::new(1), DurationMs::new(100_000), &config);
        }
        assert_eq!(low.correction(&config), config.clamp_min);
    }

    #[test]
    fn zero_prediction_is_ignored() {
        let config = CalibrationConfig::default();
        let mut window = CalibrationWindow::default();
        window.observe(DurationMs::new(100), DurationMs::ZERO, &config);
        assert_eq!(window.sample_count(), 0);
    }
}
