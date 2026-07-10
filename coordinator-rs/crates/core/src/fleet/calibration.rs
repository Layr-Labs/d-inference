//! Online bounded-window median calibration by model and hardware class.

use std::collections::{BTreeMap, VecDeque};

use serde::{Deserialize, Deserializer, Serialize, de};
use thiserror::Error;

use crate::ids::{CalibrationRevision, HardwareClass, ModelId};

/// Positive fixed-point calibration value.
///
/// Callers choose the scale (for TTFT prefill/decode ratios, thousandths are
/// recommended) and must use it consistently within one book.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct CalibrationValue(u64);

impl CalibrationValue {
    /// Creates a positive calibration sample.
    pub const fn new(value: u64) -> Result<Self, CalibrationError> {
        if value == 0 {
            Err(CalibrationError::ZeroValue)
        } else {
            Ok(Self(value))
        }
    }

    /// Returns the fixed-point sample.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl TryFrom<u64> for CalibrationValue {
    type Error = CalibrationError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<CalibrationValue> for u64 {
    fn from(value: CalibrationValue) -> Self {
        value.0
    }
}

/// Calibration series key.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct CalibrationKey {
    /// Loaded model identifier.
    pub model_id: ModelId,
    /// Provider hardware class.
    pub hardware: HardwareClass,
}

/// Bounded-window policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CalibrationPolicy {
    window_size: usize,
    minimum_samples: usize,
    clamp_minimum: CalibrationValue,
    clamp_maximum: CalibrationValue,
}

impl CalibrationPolicy {
    /// Creates a bounded-window policy.
    pub const fn new(
        window_size: usize,
        minimum_samples: usize,
        clamp_minimum: CalibrationValue,
        clamp_maximum: CalibrationValue,
    ) -> Result<Self, CalibrationError> {
        if window_size == 0 {
            return Err(CalibrationError::ZeroWindow);
        }
        if minimum_samples == 0 || minimum_samples > window_size {
            return Err(CalibrationError::InvalidMinimumSamples);
        }
        if clamp_minimum.0 > clamp_maximum.0 {
            return Err(CalibrationError::InvalidClampBounds);
        }
        Ok(Self {
            window_size,
            minimum_samples,
            clamp_minimum,
            clamp_maximum,
        })
    }
}

/// One globally revisioned observation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CalibrationEvent {
    /// Monotonically increasing observation revision.
    pub revision: CalibrationRevision,
    /// Model and hardware series.
    pub key: CalibrationKey,
    /// Positive fixed-point observation.
    pub value: CalibrationValue,
}

/// A ready median estimate.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CalibrationEstimate {
    /// Number of observations currently retained.
    pub sample_count: usize,
    /// Median before policy bounds.
    pub raw_median: CalibrationValue,
    /// Median after inclusive clamp bounds.
    pub value: CalibrationValue,
}

/// Immutable collection of bounded calibration series.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CalibrationBook {
    revision: CalibrationRevision,
    policy: CalibrationPolicyWire,
    series: BTreeMap<CalibrationKey, VecDeque<CalibrationValue>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
struct CalibrationPolicyWire {
    window_size: usize,
    minimum_samples: usize,
    clamp_minimum: CalibrationValue,
    clamp_maximum: CalibrationValue,
}

impl From<CalibrationPolicy> for CalibrationPolicyWire {
    fn from(value: CalibrationPolicy) -> Self {
        Self {
            window_size: value.window_size,
            minimum_samples: value.minimum_samples,
            clamp_minimum: value.clamp_minimum,
            clamp_maximum: value.clamp_maximum,
        }
    }
}

#[derive(Deserialize)]
struct CalibrationBookWire {
    revision: CalibrationRevision,
    policy: CalibrationPolicyWire,
    series: BTreeMap<CalibrationKey, VecDeque<CalibrationValue>>,
}

impl<'de> Deserialize<'de> for CalibrationBook {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = CalibrationBookWire::deserialize(deserializer)?;
        let policy = CalibrationPolicy::new(
            wire.policy.window_size,
            wire.policy.minimum_samples,
            wire.policy.clamp_minimum,
            wire.policy.clamp_maximum,
        )
        .map_err(de::Error::custom)?;
        if wire
            .series
            .values()
            .any(|values| values.len() > policy.window_size)
        {
            return Err(de::Error::custom(CalibrationError::WindowExceeded));
        }
        Ok(Self {
            revision: wire.revision,
            policy: policy.into(),
            series: wire.series,
        })
    }
}

impl CalibrationBook {
    /// Creates an empty calibration book at an explicit revision.
    #[must_use]
    pub fn new(revision: CalibrationRevision, policy: CalibrationPolicy) -> Self {
        Self {
            revision,
            policy: policy.into(),
            series: BTreeMap::new(),
        }
    }

    /// Returns the last accepted observation revision.
    #[must_use]
    pub const fn revision(&self) -> CalibrationRevision {
        self.revision
    }

    /// Returns the retained observation count for one key.
    #[must_use]
    pub fn sample_count(&self, key: &CalibrationKey) -> usize {
        self.series.get(key).map_or(0, VecDeque::len)
    }

    /// Returns a median only after the minimum sample threshold is met.
    #[must_use]
    pub fn estimate(&self, key: &CalibrationKey) -> Option<CalibrationEstimate> {
        let values = self.series.get(key)?;
        if values.len() < self.policy.minimum_samples {
            return None;
        }
        let mut ordered: Vec<_> = values.iter().map(|value| value.get()).collect();
        ordered.sort_unstable();
        let middle = ordered.len() / 2;
        let raw = if ordered.len() % 2 == 1 {
            ordered[middle]
        } else {
            let lower = ordered[middle - 1];
            let upper = ordered[middle];
            lower + (upper - lower) / 2
        };
        let clamped = raw.clamp(
            self.policy.clamp_minimum.get(),
            self.policy.clamp_maximum.get(),
        );
        Some(CalibrationEstimate {
            sample_count: values.len(),
            // All observations and clamp bounds are positive, so both values
            // remain valid without a fallible branch.
            raw_median: CalibrationValue(raw),
            value: CalibrationValue(clamped),
        })
    }
}

/// Applies one observation without mutating the input book.
pub fn reduce(
    state: &CalibrationBook,
    event: CalibrationEvent,
) -> Result<CalibrationBook, CalibrationError> {
    if event.revision <= state.revision {
        return Err(CalibrationError::StaleRevision {
            current: state.revision,
            supplied: event.revision,
        });
    }
    let mut next = state.clone();
    let values = next.series.entry(event.key).or_default();
    values.push_back(event.value);
    if values.len() > next.policy.window_size {
        values.pop_front();
    }
    next.revision = event.revision;
    Ok(next)
}

/// Invalid calibration policy, value, or event.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CalibrationError {
    /// Calibration values are positive.
    #[error("calibration value must be greater than zero")]
    ZeroValue,
    /// Window size must be positive.
    #[error("calibration window must be greater than zero")]
    ZeroWindow,
    /// Minimum samples must be in `1..=window_size`.
    #[error("minimum samples must be between one and the window size")]
    InvalidMinimumSamples,
    /// Clamp minimum cannot exceed clamp maximum.
    #[error("calibration clamp minimum exceeds maximum")]
    InvalidClampBounds,
    /// Persisted series cannot exceed the configured bounded window.
    #[error("persisted calibration series exceeds its configured window")]
    WindowExceeded,
    /// Observation revisions must strictly increase.
    #[error("stale calibration revision {supplied:?}; current is {current:?}")]
    StaleRevision {
        /// Last accepted revision.
        current: CalibrationRevision,
        /// Rejected revision.
        supplied: CalibrationRevision,
    },
}

#[cfg(test)]
mod tests {
    use super::{
        CalibrationBook, CalibrationError, CalibrationEvent, CalibrationKey, CalibrationPolicy,
        CalibrationValue, reduce,
    };
    use crate::ids::{CalibrationRevision, HardwareClass, ModelId};

    fn revision(value: u64) -> CalibrationRevision {
        CalibrationRevision::new(value).expect("nonzero")
    }

    fn key() -> CalibrationKey {
        CalibrationKey {
            model_id: ModelId::new("model").expect("valid"),
            hardware: HardwareClass::new("m4-max").expect("valid"),
        }
    }

    #[test]
    fn waits_clamps_and_evicts_oldest_sample() {
        let policy = CalibrationPolicy::new(
            3,
            2,
            CalibrationValue::new(10).expect("positive"),
            CalibrationValue::new(20).expect("positive"),
        )
        .expect("valid");
        let mut book = CalibrationBook::new(revision(1), policy);
        for (revision_value, value) in [(2, 1), (3, 3), (4, 100), (5, 100)] {
            book = reduce(
                &book,
                CalibrationEvent {
                    revision: revision(revision_value),
                    key: key(),
                    value: CalibrationValue::new(value).expect("positive"),
                },
            )
            .expect("fresh observation");
        }
        let estimate = book.estimate(&key()).expect("minimum met");
        assert_eq!(estimate.sample_count, 3);
        assert_eq!(estimate.raw_median.get(), 100);
        assert_eq!(estimate.value.get(), 20);
        assert_eq!(
            reduce(
                &book,
                CalibrationEvent {
                    revision: revision(5),
                    key: key(),
                    value: CalibrationValue::new(12).expect("positive"),
                },
            ),
            Err(CalibrationError::StaleRevision {
                current: revision(5),
                supplied: revision(5),
            })
        );
    }
}
