//! Candidate scoring (plan section 11.4).
//!
//! ```text
//! score = calibrated predicted first-content latency
//!       + expected decode duration (p50 measured output, not requested max)
//!       + small health adjustment
//!       + small load-spread adjustment
//! ```
//!
//! Rules enforced here:
//!
//! - Trust is a hard gate (admission), never a score term.
//! - Occupancy is counted exactly once: the provider's own first-content
//!   estimate already reflects its engine load, so the only coordinator-side
//!   load term is outstanding prepare permits — dispatches the provider has
//!   not observed yet.
//! - Expected decode uses the measured per-model p50 output, never the
//!   requested maximum (the maximum funds; it does not rank).
//! - Near ties spread deterministically from a caller-provided seed so the
//!   function stays pure.

use crate::fleet::calibration::RatioPerMille;
use crate::ids::ProviderId;
use crate::money::Tokens;
use crate::time::DurationMs;

/// Total estimated completion cost in milliseconds; lower is better.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct Score(u64);

impl Score {
    /// Test-only accessor: production ranking compares `Score`s directly.
    #[cfg(test)]
    #[must_use]
    pub(crate) const fn millis(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScoringConfig {
    /// Added when the pair is `Suspect` (small, per plan section 11.4).
    pub suspect_penalty: DurationMs,
    /// Added per outstanding prepare permit on the provider.
    pub load_spread_per_permit: DurationMs,
    /// Decode-duration stand-in when the provider has no measured decode
    /// rate yet (fresh session).
    pub unknown_decode_penalty: DurationMs,
    /// Scores within this window of the best are near-ties and are spread
    /// randomly via the tiebreak seed.
    pub near_tie_window: DurationMs,
}

impl Default for ScoringConfig {
    fn default() -> Self {
        Self {
            suspect_penalty: DurationMs::new(250),
            load_spread_per_permit: DurationMs::new(50),
            unknown_decode_penalty: DurationMs::new(5_000),
            near_tie_window: DurationMs::new(100),
        }
    }
}

/// Per-candidate scoring inputs, assembled by admission from the advisory
/// snapshot, the calibration table, and the permit book.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScoreInputs {
    /// Provider-estimated first-content latency (includes its own queue and
    /// prefill state — the single occupancy signal).
    pub predicted_first_content: DurationMs,
    /// Clamped calibration correction for (model, hardware class).
    pub calibration: RatioPerMille,
    /// Measured decode rate, tokens per second. Zero means unknown.
    pub decode_tokens_per_sec: u32,
    /// Measured per-model p50 output tokens (plan section 11.4).
    pub expected_output_tokens: Tokens,
    /// Whether the (provider, model) health state is `Suspect`.
    pub suspect: bool,
    /// Coordinator-side prepare permits outstanding on this provider.
    pub outstanding_permits: u32,
}

/// Compute one candidate's score. Pure saturating arithmetic: latency
/// estimates saturate rather than error because they rank, not bill.
#[must_use]
pub(crate) fn score(inputs: &ScoreInputs, config: &ScoringConfig) -> Score {
    let first_content = inputs.calibration.apply_to(inputs.predicted_first_content);

    let decode = if inputs.decode_tokens_per_sec == 0 {
        config.unknown_decode_penalty
    } else {
        DurationMs::new(
            u64::from(inputs.expected_output_tokens.get()).saturating_mul(1000)
                / u64::from(inputs.decode_tokens_per_sec),
        )
    };

    let health = if inputs.suspect {
        config.suspect_penalty
    } else {
        DurationMs::ZERO
    };

    let spread = DurationMs::new(
        u64::from(inputs.outstanding_permits).saturating_mul(config.load_spread_per_permit.get()),
    );

    Score(
        first_content
            .get()
            .saturating_add(decode.get())
            .saturating_add(health.get())
            .saturating_add(spread.get()),
    )
}

/// Select the winner among scored candidates: the best score wins, and
/// candidates within `near_tie_window` of the best are spread via the
/// caller-provided tiebreak seed (pure — same seed, same pick).
///
/// Ties are ordered by `ProviderId` before the seed picks, so the result is
/// independent of input order.
#[must_use]
pub(crate) fn select_best(
    scored: &[(ProviderId, Score)],
    config: &ScoringConfig,
    tiebreak_seed: u64,
) -> Option<ProviderId> {
    let best = scored.iter().map(|(_, s)| *s).min()?;
    let cutoff = best.0.saturating_add(config.near_tie_window.get());
    let mut ties: Vec<ProviderId> = scored
        .iter()
        .filter(|(_, s)| s.0 <= cutoff)
        .map(|(p, _)| *p)
        .collect();
    ties.sort_unstable();
    ties.dedup();
    let index = usize::try_from(tiebreak_seed % ties.len() as u64).unwrap_or(0);
    Some(ties[index])
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn provider(n: u128) -> ProviderId {
        ProviderId::new(Uuid::from_u128(n))
    }

    fn base_inputs() -> ScoreInputs {
        ScoreInputs {
            predicted_first_content: DurationMs::new(400),
            calibration: RatioPerMille::UNIT,
            decode_tokens_per_sec: 50,
            expected_output_tokens: Tokens::new(100),
            suspect: false,
            outstanding_permits: 0,
        }
    }

    #[test]
    fn score_sums_all_terms() {
        let config = ScoringConfig::default();
        let mut inputs = base_inputs();
        inputs.suspect = true;
        inputs.outstanding_permits = 2;
        // 400 first-content + 2000 decode (100 tok @ 50/s) + 250 suspect + 100 spread.
        assert_eq!(score(&inputs, &config).millis(), 2750);
    }

    #[test]
    fn calibration_scales_first_content_only() {
        let config = ScoringConfig::default();
        let mut inputs = base_inputs();
        inputs.calibration = RatioPerMille::new(500);
        // 200 calibrated first-content + 2000 decode.
        assert_eq!(score(&inputs, &config).millis(), 2200);
    }

    #[test]
    fn unknown_decode_rate_uses_penalty() {
        let config = ScoringConfig::default();
        let mut inputs = base_inputs();
        inputs.decode_tokens_per_sec = 0;
        assert_eq!(
            score(&inputs, &config).millis(),
            400 + config.unknown_decode_penalty.get()
        );
    }

    #[test]
    fn near_ties_spread_by_seed_far_scores_excluded() {
        let config = ScoringConfig::default();
        let scored = vec![
            (provider(1), Score(1000)),
            (provider(2), Score(1050)),
            (provider(3), Score(5000)),
        ];
        let mut winners = std::collections::BTreeSet::new();
        for seed in 0..16 {
            let w = select_best(&scored, &config, seed).expect("candidates present");
            assert_ne!(w, provider(3), "far score must never win");
            winners.insert(w);
        }
        assert_eq!(winners.len(), 2, "both near-ties should win some seed");
    }

    #[test]
    fn same_seed_same_winner() {
        let config = ScoringConfig::default();
        let scored = vec![(provider(1), Score(10)), (provider(2), Score(20))];
        assert_eq!(
            select_best(&scored, &config, 7),
            select_best(&scored, &config, 7)
        );
    }
}
