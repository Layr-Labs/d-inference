//! Pure TTFT estimation and hard/soft preflight gate policy.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::tokens::{MilliTokensPerSecond, TokenCount};

/// Positive decode-to-prefill throughput ratio in thousandths.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct PrefillDecodeRatioMilli(u64);

impl PrefillDecodeRatioMilli {
    /// Creates a positive fixed-point ratio.
    pub const fn new(value: u64) -> Result<Self, TtftError> {
        if value == 0 {
            Err(TtftError::ZeroRatio)
        } else {
            Ok(Self(value))
        }
    }

    /// Returns the fixed-point ratio.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl TryFrom<u64> for PrefillDecodeRatioMilli {
    type Error = TtftError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<PrefillDecodeRatioMilli> for u64 {
    fn from(value: PrefillDecodeRatioMilli) -> Self {
        value.0
    }
}

/// Hard-reject or soft-preference TTFT policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TtftGateMode {
    /// Reject when the best reliable estimate misses the deadline.
    Hard,
    /// Keep TTFT as a ranking preference and do not reject.
    Soft,
}

/// Preflight outcome shared by capacity and TTFT policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TtftOutcome {
    /// At least one candidate may proceed.
    Served,
    /// No candidate has capacity.
    MachineBusy,
    /// Candidates exist, but the best reliable TTFT misses the deadline.
    TtftTooSlow,
}

/// Estimates idle warm-provider TTFT with checked integer arithmetic.
///
/// The estimate is prompt prefill time plus one effective decode step. Division
/// rounds up because underestimating a deadline cost would be unsafe.
pub fn estimate_idle_ttft_microseconds(
    prompt_tokens: TokenCount,
    ratio: PrefillDecodeRatioMilli,
    static_decode_rate: MilliTokensPerSecond,
    effective_decode_rate: MilliTokensPerSecond,
) -> Result<u64, TtftError> {
    // static milli-token/s × ratio-milli / 1_000_000 = prefill token/s.
    // token count × 1_000_000 us/s therefore has numerator 1e12.
    let prefill_numerator = u128::from(prompt_tokens.get())
        .checked_mul(1_000_000_000_000)
        .ok_or(TtftError::Overflow)?;
    let prefill_denominator = u128::from(static_decode_rate.get())
        .checked_mul(u128::from(ratio.get()))
        .ok_or(TtftError::Overflow)?;
    // One token at milli-token/s: 1_000 milli-tokens × 1_000_000 us/s.
    let effective_denominator = u128::from(effective_decode_rate.get());
    // Sum the rational terms before rounding so the conservative estimate
    // incurs at most one microsecond of rounding.
    let numerator = prefill_numerator
        .checked_mul(effective_denominator)
        .and_then(|value| {
            1_000_000_000_u128
                .checked_mul(prefill_denominator)
                .and_then(|decode| value.checked_add(decode))
        })
        .ok_or(TtftError::Overflow)?;
    let denominator = prefill_denominator
        .checked_mul(effective_denominator)
        .ok_or(TtftError::Overflow)?;
    let total = div_ceil(numerator, denominator)?;
    u64::try_from(total).map_err(|_| TtftError::Overflow)
}

/// Applies capacity classification and the configured TTFT gate.
#[must_use]
pub const fn evaluate_ttft_gate(
    candidate_count: u32,
    capacity_rejections: u32,
    best_ttft_microseconds: Option<u64>,
    deadline_microseconds: u64,
    mode: TtftGateMode,
) -> TtftOutcome {
    if candidate_count == 0 && capacity_rejections > 0 {
        return TtftOutcome::MachineBusy;
    }
    if matches!(mode, TtftGateMode::Hard)
        && matches!(best_ttft_microseconds, Some(best) if best > deadline_microseconds)
    {
        return TtftOutcome::TtftTooSlow;
    }
    TtftOutcome::Served
}

fn div_ceil(numerator: u128, denominator: u128) -> Result<u128, TtftError> {
    if numerator == 0 {
        return Ok(0);
    }
    numerator
        .checked_add(denominator - 1)
        .map(|value| value / denominator)
        .ok_or(TtftError::Overflow)
}

/// Invalid TTFT ratio or arithmetic overflow.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum TtftError {
    /// Decode-to-prefill ratio must be positive.
    #[error("prefill/decode ratio must be greater than zero")]
    ZeroRatio,
    /// TTFT estimation exceeded its integer representation.
    #[error("TTFT estimate overflow")]
    Overflow,
}

#[cfg(test)]
mod tests {
    use super::{
        PrefillDecodeRatioMilli, TtftGateMode, TtftOutcome, estimate_idle_ttft_microseconds,
        evaluate_ttft_gate,
    };
    use crate::tokens::{MilliTokensPerSecond, TokenCount};

    #[test]
    fn estimate_and_gate_are_boundary_exact() {
        let estimate = estimate_idle_ttft_microseconds(
            TokenCount::new(1_000),
            PrefillDecodeRatioMilli::new(4_000).expect("positive"),
            MilliTokensPerSecond::new(25_000).expect("positive"),
            MilliTokensPerSecond::new(25_000).expect("positive"),
        )
        .expect("estimate");
        assert_eq!(estimate, 10_040_000);
        assert_eq!(
            evaluate_ttft_gate(1, 0, Some(5_001), 5_000, TtftGateMode::Hard),
            TtftOutcome::TtftTooSlow
        );
        assert_eq!(
            evaluate_ttft_gate(1, 0, Some(5_001), 5_000, TtftGateMode::Soft),
            TtftOutcome::Served
        );
        assert_eq!(
            evaluate_ttft_gate(0, 1, None, 5_000, TtftGateMode::Soft),
            TtftOutcome::MachineBusy
        );
    }
}
