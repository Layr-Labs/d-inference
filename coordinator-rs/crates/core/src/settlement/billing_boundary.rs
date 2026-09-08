//! The billing boundary: caps provider-claimed usage at the accepted-chunk
//! checkpoint and the frozen funded bound, flagging every cap that bit
//! (plan sections 9.3.8, 10.6, 13.6).

use serde::{Deserialize, Serialize};

use crate::money::Tokens;

/// Why settled usage was flagged for operator review.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageReviewFlag {
    /// Provider-claimed completion tokens exceeded the coordinator's
    /// last-accepted-chunk checkpoint (plan sections 10.6, 13.6).
    CompletionExceedsAcceptedCheckpoint,
    /// Provider-claimed completion tokens exceeded the frozen funded output
    /// bound — a provider protocol violation (plan section 9.3.8).
    CompletionExceedsFundedBound,
    /// Provider-claimed prompt tokens differ from the frozen billable input
    /// (plan section 12.4 freezes exact billable input).
    PromptDiffersFromFrozenInput,
}

/// Usage the provider claims in its signed terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderClaimedUsage {
    pub prompt_tokens: Tokens,
    pub completion_tokens: Tokens,
}

/// Billable completion after applying both caps (accepted checkpoint and
/// funded bound). Pure `min`, with flags for every cap that bit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillableCompletion {
    pub tokens: Tokens,
    pub review_flags: Vec<UsageReviewFlag>,
}

/// Cap provider-claimed completion usage at the billing boundary
/// (plan section 13.6) and the frozen funded bound (plan section 9.3.8).
///
/// `accepted_checkpoint` is the cumulative completion-token count of the last
/// chunk successfully enqueued into the consumer-output pipe.
#[must_use]
pub fn billable_completion(
    claimed: Tokens,
    accepted_checkpoint: Tokens,
    funded_bound: Tokens,
) -> BillableCompletion {
    let mut review_flags = Vec::new();
    if claimed > accepted_checkpoint {
        review_flags.push(UsageReviewFlag::CompletionExceedsAcceptedCheckpoint);
    }
    if claimed > funded_bound {
        review_flags.push(UsageReviewFlag::CompletionExceedsFundedBound);
    }
    BillableCompletion {
        tokens: claimed.min(accepted_checkpoint).min(funded_bound),
        review_flags,
    }
}
