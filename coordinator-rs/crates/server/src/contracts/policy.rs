//! Shared request policy and the atomically-swapped catalog snapshot
//! (plan §8): read by HTTP, request tasks, and the fleet actor.

use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;

use darkbloom_core::settlement::MicroUsdPerMTokens;

/// Versioned request policy read by HTTP, request tasks, and the fleet actor.
#[derive(Debug, Clone)]
pub struct RequestPolicy {
    /// First-content deadline: base + per-estimated-prompt-token (plan §16).
    pub first_content_base: Duration,
    pub first_content_per_prompt_token: Duration,
    /// Absolute request deadline created at ingress (plan §16).
    pub request_deadline: Duration,
    /// Prepare-stage hedge (plan §11.8).
    pub hedge_enabled: bool,
    /// Fraction of admissions allowed to hedge (must be < 0.10).
    pub hedge_budget_fraction: f64,
    /// Primary-prepare latency timer that triggers the hedge.
    pub hedge_prepare_timeout: Duration,
    /// Hard timeout for a prepare reply before the attempt is failed.
    pub prepare_deadline: Duration,
    /// Bounded wait for a terminal after cancellation (plan §13.5).
    pub terminal_wait: Duration,
    /// Consumer chunk pipe: the grace window in bytes/items (plan §13.6).
    pub pipe_max_items: usize,
    pub pipe_max_bytes: usize,
    /// Idle timeout between streamed chunks.
    pub stream_idle_timeout: Duration,
    /// Provider payout share of the consumer charge, parts-per-million
    /// (plan §12.4: frozen into settlement terms before start). The platform
    /// fee is the exact remainder after payout (and referral, when present)
    /// per `darkbloom_core::settlement::split_charge` semantics.
    pub provider_payout_ppm: u32,
}

/// One model's public pricing card: exact integer micro-USD per ONE MILLION
/// tokens (the legacy `model_prices` unit, plan §11.5).
///
/// Rates stay per-MTok so sub-micro-USD per-token prices never round.
/// Per-request costs are computed under the frozen
/// [`darkbloom_core::settlement::RoundingVersion`]: reservations and
/// settlement both round UP (`CeilV1`), so a reservation can never
/// under-cover the charge settled from the same frozen rates.
#[derive(Debug, Clone, Copy)]
pub struct PriceCard {
    pub prompt_micro_per_mtok: MicroUsdPerMTokens,
    pub completion_micro_per_mtok: MicroUsdPerMTokens,
}

impl PriceCard {
    pub const ZERO: Self = Self {
        prompt_micro_per_mtok: MicroUsdPerMTokens::ZERO,
        completion_micro_per_mtok: MicroUsdPerMTokens::ZERO,
    };
}

/// Immutable catalog snapshot (plan §8): public model -> concrete build,
/// pricing, and capability floors. Swapped atomically, never mutated.
#[derive(Debug, Clone, Default)]
pub struct CatalogSnapshot {
    pub version: u64,
    /// public/alias model id -> concrete build id.
    pub aliases: std::collections::HashMap<String, String>,
    /// concrete build id -> price card.
    pub prices: std::collections::HashMap<String, PriceCard>,
}

pub type SharedCatalog = Arc<ArcSwap<CatalogSnapshot>>;
