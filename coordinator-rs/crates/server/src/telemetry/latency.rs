//! Bounded latency samples with a minimum evidence threshold.

use std::{collections::VecDeque, sync::Mutex, time::Duration};

use thiserror::Error;

/// Hard bound for one latency window.
pub const MAX_LATENCY_SAMPLES: usize = 65_536;

/// Stable summary emitted only after enough samples exist.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LatencySummary {
    /// Number of retained samples.
    pub samples: usize,
    /// Minimum retained latency.
    pub minimum: Duration,
    /// Nearest-rank median.
    pub p50: Duration,
    /// Nearest-rank p95.
    pub p95: Duration,
    /// Nearest-rank p99.
    pub p99: Duration,
    /// Maximum retained latency.
    pub maximum: Duration,
}

/// FIFO latency window with finite memory and minimum sample count.
#[derive(Debug)]
pub struct LatencyWindow {
    capacity: usize,
    minimum_samples: usize,
    samples: Mutex<VecDeque<Duration>>,
}

impl LatencyWindow {
    /// Creates a finite window whose summary is unavailable below `minimum_samples`.
    pub fn new(capacity: usize, minimum_samples: usize) -> Result<Self, LatencyConfigError> {
        if capacity == 0 {
            return Err(LatencyConfigError::ZeroCapacity);
        }
        if capacity > MAX_LATENCY_SAMPLES {
            return Err(LatencyConfigError::CapacityTooLarge {
                actual: capacity,
                maximum: MAX_LATENCY_SAMPLES,
            });
        }
        if minimum_samples == 0 || minimum_samples > capacity {
            return Err(LatencyConfigError::InvalidMinimum {
                minimum: minimum_samples,
                capacity,
            });
        }
        Ok(Self {
            capacity,
            minimum_samples,
            samples: Mutex::new(VecDeque::with_capacity(capacity)),
        })
    }

    /// Records one sample, evicting the oldest at capacity.
    pub fn record(&self, latency: Duration) {
        let mut samples = self.lock_samples();
        if samples.len() == self.capacity {
            samples.pop_front();
        }
        samples.push_back(latency);
    }

    /// Summarizes only when the configured minimum evidence exists.
    #[must_use]
    pub fn summary(&self) -> Option<LatencySummary> {
        let samples = self.lock_samples();
        if samples.len() < self.minimum_samples {
            return None;
        }
        let mut sorted: Vec<_> = samples.iter().copied().collect();
        sorted.sort_unstable();
        Some(LatencySummary {
            samples: sorted.len(),
            minimum: sorted[0],
            p50: percentile(&sorted, 50),
            p95: percentile(&sorted, 95),
            p99: percentile(&sorted, 99),
            maximum: sorted[sorted.len() - 1],
        })
    }

    /// Retained sample count.
    #[must_use]
    pub fn len(&self) -> usize {
        self.lock_samples().len()
    }

    /// Returns whether no samples are retained.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lock_samples().is_empty()
    }

    /// Minimum count required before percentile publication.
    #[must_use]
    pub const fn minimum_samples(&self) -> usize {
        self.minimum_samples
    }

    fn lock_samples(&self) -> std::sync::MutexGuard<'_, VecDeque<Duration>> {
        self.samples
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn percentile(sorted: &[Duration], percentile: usize) -> Duration {
    let rank = percentile
        .saturating_mul(sorted.len())
        .div_ceil(100)
        .clamp(1, sorted.len());
    sorted[rank - 1]
}

/// Invalid bounded latency policy.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum LatencyConfigError {
    /// Window must retain at least one sample.
    #[error("latency sample capacity must be greater than zero")]
    ZeroCapacity,
    /// Window exceeds defensive hard cap.
    #[error("latency sample capacity {actual} exceeds hard maximum {maximum}")]
    CapacityTooLarge {
        /// Configured capacity.
        actual: usize,
        /// Hard maximum.
        maximum: usize,
    },
    /// Minimum evidence must fit inside the retained window.
    #[error("latency minimum sample count {minimum} is invalid for capacity {capacity}")]
    InvalidMinimum {
        /// Configured evidence threshold.
        minimum: usize,
        /// Retained window bound.
        capacity: usize,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_waits_for_minimum_and_fifo_remains_bounded() {
        let window = LatencyWindow::new(3, 2).expect("window");
        window.record(Duration::from_millis(30));
        assert!(window.summary().is_none());
        window.record(Duration::from_millis(10));
        let summary = window.summary().expect("minimum reached");
        assert_eq!(summary.minimum, Duration::from_millis(10));
        assert_eq!(summary.p50, Duration::from_millis(10));
        window.record(Duration::from_millis(20));
        window.record(Duration::from_millis(40));
        assert_eq!(window.len(), 3);
        let summary = window.summary().expect("summary");
        assert_eq!(summary.minimum, Duration::from_millis(10));
        assert_eq!(summary.maximum, Duration::from_millis(40));
    }
}
