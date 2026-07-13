//! Deterministic integer cost scoring with stable provider tie-breaking.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    ids::ProviderId,
    money::MicroUsd,
    tokens::{MilliTokensPerSecond, TokenCount},
};

/// Scoring weights in integer microseconds.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScoringPolicy {
    /// Latency-equivalent cost per micro-USD.
    pub microseconds_per_micro_usd: u64,
    /// Cost added for every queued request.
    pub queue_penalty_microseconds: u64,
}

/// Inputs used to score one already-admissible provider.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Candidate {
    /// Stable provider identity.
    pub provider_id: ProviderId,
    /// This request's model-prefill time.
    pub request_prefill_microseconds: u64,
    /// Requested maximum completion length.
    pub completion_tokens: TokenCount,
    /// Effective decode throughput after load degradation.
    pub decode_rate: MilliTokensPerSecond,
    /// Checked request quote for this provider.
    pub quoted_price: MicroUsd,
    /// Requests already queued at the provider.
    pub queue_depth: u32,
    /// Model slot-state penalty.
    pub state_penalty_microseconds: u64,
    /// Provider-wide pending-request penalty.
    pub pending_penalty_microseconds: u64,
    /// Decode backlog penalty.
    pub backlog_penalty_microseconds: u64,
    /// Memory, CPU, thermal, and GPU-utilization penalty.
    pub health_penalty_microseconds: u64,
    /// Capacity-rejection-rate penalty.
    pub capacity_rate_penalty_microseconds: u64,
}

/// A nonnegative deterministic cost in latency-equivalent microseconds.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CostScore(u64);

impl CostScore {
    /// Returns the integer score.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Scored candidate with auditable components.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScoredCandidate {
    /// Provider identity.
    pub provider_id: ProviderId,
    /// Total cost used for ranking.
    pub total: CostScore,
    /// Model slot-state component.
    pub state_microseconds: u64,
    /// Queue component.
    pub queue_microseconds: u64,
    /// Provider-wide pending-request component.
    pub pending_microseconds: u64,
    /// Decode backlog component.
    pub backlog_microseconds: u64,
    /// This request's prefill component.
    pub request_prefill_microseconds: u64,
    /// This request's completion-decode component.
    pub decode_microseconds: u64,
    /// This request's complete prefill-plus-decode component.
    pub this_request_microseconds: u64,
    /// Provider health component.
    pub health_microseconds: u64,
    /// Capacity-rejection-rate component.
    pub capacity_rate_microseconds: u64,
    /// Price component.
    pub price_microseconds: u64,
}

/// Scores a candidate using Go-compatible latency components.
///
/// The request component is prefill plus completion decode; TTFT's
/// first-decode latency is deliberately not added because the completion
/// reservation already includes every requested decode token.
pub fn score(candidate: Candidate, policy: ScoringPolicy) -> Result<ScoredCandidate, ScoringError> {
    // tokens * 1_000 converts tokens to milli-tokens; multiplying by one
    // million converts seconds to microseconds.
    let decode_numerator = u128::from(candidate.completion_tokens.get())
        .checked_mul(1_000_000_000)
        .ok_or(ScoringError::Overflow)?;
    let decode_microseconds = div_ceil(decode_numerator, u128::from(candidate.decode_rate.get()))?;
    let price_microseconds = u128::from(candidate.quoted_price.get())
        .checked_mul(u128::from(policy.microseconds_per_micro_usd))
        .ok_or(ScoringError::Overflow)?;
    let queue_microseconds = u128::from(candidate.queue_depth)
        .checked_mul(u128::from(policy.queue_penalty_microseconds))
        .ok_or(ScoringError::Overflow)?;
    let this_request_microseconds = u128::from(candidate.request_prefill_microseconds)
        .checked_add(decode_microseconds)
        .ok_or(ScoringError::Overflow)?;
    let total = u128::from(candidate.state_penalty_microseconds)
        .checked_add(queue_microseconds)
        .and_then(|value| value.checked_add(u128::from(candidate.pending_penalty_microseconds)))
        .and_then(|value| value.checked_add(u128::from(candidate.backlog_penalty_microseconds)))
        .and_then(|value| value.checked_add(this_request_microseconds))
        .and_then(|value| value.checked_add(u128::from(candidate.health_penalty_microseconds)))
        .and_then(|value| {
            value.checked_add(u128::from(candidate.capacity_rate_penalty_microseconds))
        })
        .and_then(|value| value.checked_add(price_microseconds))
        .ok_or(ScoringError::Overflow)?;

    Ok(ScoredCandidate {
        provider_id: candidate.provider_id,
        total: CostScore(to_u64(total)?),
        state_microseconds: candidate.state_penalty_microseconds,
        queue_microseconds: to_u64(queue_microseconds)?,
        pending_microseconds: candidate.pending_penalty_microseconds,
        backlog_microseconds: candidate.backlog_penalty_microseconds,
        request_prefill_microseconds: candidate.request_prefill_microseconds,
        decode_microseconds: to_u64(decode_microseconds)?,
        this_request_microseconds: to_u64(this_request_microseconds)?,
        health_microseconds: candidate.health_penalty_microseconds,
        capacity_rate_microseconds: candidate.capacity_rate_penalty_microseconds,
        price_microseconds: to_u64(price_microseconds)?,
    })
}

/// Scores and ranks candidates by total cost, then stable provider identity.
///
/// The result is independent of input iteration order.
pub fn rank(
    candidates: impl IntoIterator<Item = Candidate>,
    policy: ScoringPolicy,
) -> Result<Vec<ScoredCandidate>, ScoringError> {
    let mut seen = BTreeSet::new();
    let mut scored = Vec::new();
    for candidate in candidates {
        if !seen.insert(candidate.provider_id) {
            return Err(ScoringError::DuplicateProvider(candidate.provider_id));
        }
        scored.push(score(candidate, policy)?);
    }
    scored.sort_by_key(|candidate| (candidate.total, candidate.provider_id));
    Ok(scored)
}

fn div_ceil(numerator: u128, denominator: u128) -> Result<u128, ScoringError> {
    if numerator == 0 {
        return Ok(0);
    }
    numerator
        .checked_add(denominator - 1)
        .map(|value| value / denominator)
        .ok_or(ScoringError::Overflow)
}

fn to_u64(value: u128) -> Result<u64, ScoringError> {
    u64::try_from(value).map_err(|_| ScoringError::Overflow)
}

/// Invalid candidate set or score overflow.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ScoringError {
    /// One scoring component or their sum exceeded `u64`.
    #[error("candidate cost score overflow")]
    Overflow,
    /// A provider appeared more than once in a candidate set.
    #[error("provider {0} appears more than once")]
    DuplicateProvider(ProviderId),
}

#[cfg(test)]
mod tests {
    use super::{Candidate, ScoringError, ScoringPolicy, rank, score};
    use crate::{
        ids::ProviderId,
        money::MicroUsd,
        tokens::{MilliTokensPerSecond, TokenCount},
    };

    fn candidate(provider_id: ProviderId) -> Candidate {
        Candidate {
            provider_id,
            request_prefill_microseconds: 10,
            completion_tokens: TokenCount::new(5),
            decode_rate: MilliTokensPerSecond::new(1_000).expect("nonzero"),
            quoted_price: MicroUsd::new(2),
            queue_depth: 1,
            state_penalty_microseconds: 0,
            pending_penalty_microseconds: 0,
            backlog_penalty_microseconds: 0,
            health_penalty_microseconds: 0,
            capacity_rate_penalty_microseconds: 0,
        }
    }

    #[test]
    fn ties_are_stable_across_input_orders() {
        let a = ProviderId::new(uuid::Uuid::from_u128(1)).expect("non-nil");
        let b = ProviderId::new(uuid::Uuid::from_u128(2)).expect("non-nil");
        let policy = ScoringPolicy {
            microseconds_per_micro_usd: 3,
            queue_penalty_microseconds: 4,
        };
        let forward = rank([candidate(a), candidate(b)], policy).expect("scores");
        let reverse = rank([candidate(b), candidate(a)], policy).expect("scores");
        assert_eq!(forward, reverse);
        assert_eq!(forward[0].provider_id, a);
    }

    #[test]
    fn idle_warm_zero_price_score_has_go_compatible_components() {
        let provider_id = ProviderId::new(uuid::Uuid::from_u128(1)).expect("non-nil");
        let scored = score(
            Candidate {
                provider_id,
                request_prefill_microseconds: 355_556,
                completion_tokens: TokenCount::new(256),
                decode_rate: MilliTokensPerSecond::new(60_000).expect("nonzero"),
                quoted_price: MicroUsd::ZERO,
                queue_depth: 0,
                state_penalty_microseconds: 0,
                pending_penalty_microseconds: 0,
                backlog_penalty_microseconds: 0,
                health_penalty_microseconds: 550_000,
                capacity_rate_penalty_microseconds: 0,
            },
            ScoringPolicy {
                microseconds_per_micro_usd: 0,
                queue_penalty_microseconds: 0,
            },
        )
        .expect("bounded score");

        assert_eq!(scored.request_prefill_microseconds, 355_556);
        assert_eq!(scored.decode_microseconds, 4_266_667);
        assert_eq!(scored.this_request_microseconds, 4_622_223);
        assert_eq!(scored.health_microseconds, 550_000);
        assert_eq!(scored.total.get(), 5_172_223);
    }

    #[test]
    fn component_sum_overflow_is_rejected() {
        let provider_id = ProviderId::new(uuid::Uuid::from_u128(1)).expect("non-nil");
        let mut input = candidate(provider_id);
        input.request_prefill_microseconds = u64::MAX;
        input.completion_tokens = TokenCount::ZERO;
        input.state_penalty_microseconds = 1;
        assert_eq!(
            score(
                input,
                ScoringPolicy {
                    microseconds_per_micro_usd: 0,
                    queue_penalty_microseconds: 0,
                },
            ),
            Err(ScoringError::Overflow)
        );
    }
}
