//! Admission input types: the request's traits and the caller-assembled
//! per-candidate snapshot.

use crate::fleet::calibration::RatioPerMille;
use crate::fleet::health::{HealthState, SecurityFence};
use crate::fleet::model_presence::ModelPresence;
use crate::ids::{AccountId, ModelId, ProviderId};
use crate::money::Tokens;
use crate::time::DurationMs;

/// Shape of the request being admitted (plan section 11.2 hard gates:
/// vision, tools, media, and other request traits).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestTraits {
    pub model: ModelId,
    pub needs_vision: bool,
    pub needs_tools: bool,
    pub needs_media: bool,
    /// Paid public routing requires a provider beneficiary identity.
    pub paid: bool,
    /// Measured per-model p50 output tokens (plan section 11.4: rank on the
    /// distribution, never the requested maximum).
    pub expected_output_tokens: Tokens,
}

/// One candidate as the fleet actor sees it at admission time. Everything
/// here is advisory input assembled by the caller; `admit` only decides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CandidateSnapshot {
    pub provider: ProviderId,
    /// The provider has an active, current session epoch (plan 11.2).
    pub session_current: bool,
    /// Trust hard gate: verified trust at the required level.
    pub trusted: bool,
    /// Attestation challenge freshness hard gate.
    pub challenge_fresh: bool,
    /// Runtime and encrypted-transport integrity hard gate.
    pub runtime_integrity: bool,
    /// Canonical model presence for the requested model (plan 10.7).
    pub model_presence: ModelPresence,
    pub supports_vision: bool,
    pub supports_tools: bool,
    pub supports_media: bool,
    /// Beneficiary account for paid routing, when configured.
    pub beneficiary: Option<AccountId>,
    /// Per (provider, model) health state (plan 11.6).
    pub health: HealthState,
    /// Machine-wide security fence (plan 11.6).
    pub security: SecurityFence,
    /// Writer data-lane headroom flag (plan 9.4.2, 14).
    pub data_lane_headroom: bool,
    /// Writer control-lane headroom flag (plan 14: check both lanes).
    pub control_lane_headroom: bool,
    /// Prepare permits currently outstanding on this provider.
    pub outstanding_permits: u32,
    /// Advisory outstanding-prepare bound from heartbeat capacity (plan 11.3).
    pub max_outstanding_permits: u32,
    /// Advisory capacity says the provider can plausibly take this request.
    /// Invalidated by capacity rejections until fresh state arrives.
    pub advisory_capacity_ok: bool,
    /// Provider-estimated first-content latency (single occupancy signal).
    pub predicted_first_content: DurationMs,
    /// Measured decode rate, tokens/second; zero when unknown.
    pub decode_tokens_per_sec: u32,
    /// Clamped calibration correction for (model, hardware class), looked up
    /// by the caller from the [`crate::fleet::calibration::CalibrationTable`].
    pub calibration: RatioPerMille,
}
