//! Property tests for the fleet modules: calibration clamp (plan 11.4),
//! health-machine quarantine discipline (plan 11.6), permit accounting
//! (plan 9.2.10), hedge budget bounds (plan 11.8), and admission decision
//! soundness (plan 11.1-11.3).

use std::collections::BTreeSet;

use darkbloom_core::fleet::admission::{
    admit, AdmissionConfig, AdmissionDecision, CandidateSnapshot, RejectionReason, RequestTraits,
};
use darkbloom_core::fleet::calibration::{CalibrationConfig, CalibrationWindow, RatioPerMille};
use darkbloom_core::fleet::health::{
    apply as health_apply, HealthConfig, HealthEvent, HealthState, SecurityFence,
};
use darkbloom_core::fleet::hedge::{HedgeBudget, HedgeConfig};
use darkbloom_core::fleet::model_presence::ModelPresence;
use darkbloom_core::fleet::permits::{PermitBook, ReleaseOutcome};
use darkbloom_core::ids::{AccountId, ModelId, PermitId, ProviderId};
use darkbloom_core::money::Tokens;
use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_core::time::{DurationMs, TimestampMs};
use proptest::prelude::*;
use uuid::Uuid;

// ---------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1024))]

    /// The correction is always inside the configured clamp, for any sample
    /// stream (plan 11.4).
    #[test]
    fn calibration_always_within_clamp(
        samples in proptest::collection::vec((0u64..1_000_000, 0u64..1_000_000), 0..300),
        clamp_min in 1u32..1_000,
        clamp_span in 1u32..2_000,
        min_samples in 0usize..32,
        window in 1usize..200,
    ) {
        let config = CalibrationConfig {
            window,
            clamp_min: RatioPerMille::new(clamp_min),
            clamp_max: RatioPerMille::new(clamp_min + clamp_span),
            min_samples,
        };
        let mut w = CalibrationWindow::default();
        for (actual, predicted) in samples {
            w.observe(DurationMs::new(actual), DurationMs::new(predicted), &config);
            let c = w.correction(&config);
            prop_assert!(c >= config.clamp_min, "correction below clamp floor");
            prop_assert!(c <= config.clamp_max, "correction above clamp ceiling");
        }
    }
}

// ---------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------

fn health_event_strategy() -> impl Strategy<Value = HealthEvent> {
    prop_oneof![
        Just(HealthEvent::Success),
        Just(HealthEvent::ProviderError(ProviderErrorClass::Fault)),
        Just(HealthEvent::ProviderError(ProviderErrorClass::Capacity)),
        Just(HealthEvent::ProviderError(
            ProviderErrorClass::InvalidRequest
        )),
        Just(HealthEvent::ProviderError(ProviderErrorClass::Security)),
        Just(HealthEvent::ProbeDispatched),
        Just(HealthEvent::ProbeSucceeded),
        Just(HealthEvent::ProbeFailed),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1024))]

    /// No accepted transition moves quarantined directly to healthy: the
    /// only route is an expired quarantine, a dispatched probe (half-open),
    /// and a probe success (plan 11.6).
    #[test]
    fn quarantine_cannot_skip_half_open(
        events in proptest::collection::vec((health_event_strategy(), 0i64..200_000), 1..200)
    ) {
        let config = HealthConfig::default();
        let mut state = HealthState::Healthy;
        for (event, now) in events {
            let now = TimestampMs::new(now);
            let Ok(next) = health_apply(state, event, now, &config) else {
                continue; // rejected events leave state unchanged
            };
            // The forbidden edge.
            if matches!(state, HealthState::Quarantined { .. }) {
                prop_assert_ne!(
                    next,
                    HealthState::Healthy,
                    "quarantined -> healthy without a half-open probe"
                );
            }
            // Reaching healthy is only possible from healthy/suspect
            // (success) or half-open (probe success).
            if next == HealthState::Healthy && state != HealthState::Healthy {
                prop_assert!(
                    matches!(state, HealthState::Suspect | HealthState::HalfOpen),
                    "healthy reached from {state:?}"
                );
            }
            // Probe results require an outstanding probe.
            if matches!(event, HealthEvent::ProbeSucceeded | HealthEvent::ProbeFailed) {
                prop_assert_eq!(state, HealthState::HalfOpen);
            }
            state = next;
        }
    }

    /// `invalid_request` and `capacity` never change health state
    /// (plan 11.6); `security` never touches the per-model machine.
    #[test]
    fn non_fault_classes_never_move_health(
        start in prop_oneof![
            Just(HealthState::Healthy),
            Just(HealthState::Suspect),
            Just(HealthState::HalfOpen),
            (0i64..10_000).prop_map(|t| HealthState::Quarantined { until: TimestampMs::new(t) }),
        ],
        class in prop_oneof![
            Just(ProviderErrorClass::InvalidRequest),
            Just(ProviderErrorClass::Capacity),
            Just(ProviderErrorClass::ModelNotReady),
            Just(ProviderErrorClass::Draining),
            Just(ProviderErrorClass::Cancelled),
            Just(ProviderErrorClass::Security),
        ],
        now in 0i64..20_000,
    ) {
        let next = health_apply(
            start,
            HealthEvent::ProviderError(class),
            TimestampMs::new(now),
            &HealthConfig::default(),
        ).expect("non-probe events are always accepted");
        prop_assert_eq!(next, start);
    }
}

#[test]
fn security_fence_never_clears_from_events() {
    let mut fence = SecurityFence::Clear.observe(ProviderErrorClass::Security);
    for class in [
        ProviderErrorClass::InvalidRequest,
        ProviderErrorClass::Capacity,
        ProviderErrorClass::Cancelled,
        ProviderErrorClass::Fault,
    ] {
        fence = fence.observe(class);
        assert!(fence.is_fenced());
    }
}

// ---------------------------------------------------------------------
// Permits
// ---------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// Permit accounting against a reference model: counts never go
    /// negative, double releases are visible no-ops, expiry is idempotent,
    /// and the per-provider bound holds (plan 9.2.10, 11.3).
    #[test]
    fn permit_book_matches_reference_model(
        ops in proptest::collection::vec((0u8..4, 0u8..24, 0u8..4, 0u64..2_000), 1..300)
    ) {
        let mut book = PermitBook::new();
        let mut model: BTreeSet<u8> = BTreeSet::new(); // outstanding permit ns
        let mut now = 0i64;
        let max_outstanding = 3u32;
        let mut expiries: std::collections::HashMap<u8, i64> = std::collections::HashMap::new();

        for (op, permit_n, provider_n, arg) in ops {
            let permit = PermitId::new(Uuid::from_u128(u128::from(permit_n)));
            let provider = ProviderId::new(Uuid::from_u128(0x100 + u128::from(provider_n)));
            match op {
                0 => {
                    let result = book.reserve(
                        permit, provider, TimestampMs::new(now),
                        DurationMs::new(arg + 1), max_outstanding,
                    );
                    if result.is_ok() {
                        prop_assert!(!model.contains(&permit_n), "duplicate id accepted");
                        model.insert(permit_n);
                        expiries.insert(permit_n, now + i64::try_from(arg + 1).expect("small"));
                    }
                }
                1 => {
                    let outcome = book.release(permit);
                    let was_present = model.remove(&permit_n);
                    expiries.remove(&permit_n);
                    prop_assert_eq!(
                        outcome == ReleaseOutcome::Released,
                        was_present,
                        "release outcome disagrees with the model"
                    );
                }
                2 => {
                    let expired = book.expire(TimestampMs::new(now));
                    for id in &expired {
                        // Every reported expiry was outstanding and due.
                        let n = u8::try_from(id.get().as_u128()).expect("small ids");
                        prop_assert!(model.remove(&n));
                        let due = expiries.remove(&n).expect("tracked expiry");
                        prop_assert!(now >= due, "expired before its hard expiry");
                    }
                }
                _ => now += i64::try_from(arg).expect("small"),
            }
            prop_assert_eq!(book.total_outstanding(), model.len());
            // Per-provider bound invariant.
            for p in 0u8..4 {
                let provider = ProviderId::new(Uuid::from_u128(0x100 + u128::from(p)));
                prop_assert!(book.outstanding_for(provider) <= max_outstanding);
            }
        }
    }
}

// ---------------------------------------------------------------------
// Hedge budget
// ---------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// The budget never exceeds the burst cap, never acquires when empty,
    /// and its milli-token ledger matches a reference counter (plan 11.8).
    #[test]
    fn hedge_budget_matches_reference(
        fraction in 0u32..100_000,
        cap in 1u32..16,
        ops in proptest::collection::vec(0u8..3, 1..500),
    ) {
        let config = HedgeConfig::new(fraction, cap).expect("valid by construction");
        let mut budget = HedgeBudget::new(config);
        let cap_micro = u64::from(cap) * 1_000_000;
        let mut reference: u64 = 1_000_000.min(cap_micro);
        let mut held_tokens = 0u32;

        for op in ops {
            match op {
                0 => {
                    budget.on_admission();
                    reference = (reference + u64::from(fraction)).min(cap_micro);
                }
                1 => {
                    let acquired = budget.try_acquire();
                    if reference >= 1_000_000 {
                        prop_assert!(acquired.is_some(), "budget refused with tokens available");
                        reference -= 1_000_000;
                        held_tokens += 1;
                    } else {
                        prop_assert!(acquired.is_none(), "budget minted a token");
                    }
                }
                _ => {
                    if held_tokens > 0 {
                        // Refund one held token (acquire again to get a
                        // token value — the type is opaque by design).
                        held_tokens -= 1;
                        // Reacquire path: we simulate refund via a fresh
                        // acquire+refund pair only when possible.
                        if let Some(token) = budget.try_acquire() {
                            budget.refund(token);
                        }
                    }
                }
            }
            prop_assert_eq!(budget.available(), u32::try_from(reference / 1_000_000).expect("bounded"));
            prop_assert!(budget.available() <= cap);
        }
    }
}

// ---------------------------------------------------------------------
// Admission
// ---------------------------------------------------------------------

fn eligible_candidate(n: u128) -> CandidateSnapshot {
    CandidateSnapshot {
        provider: ProviderId::new(Uuid::from_u128(0x9000 + n)),
        session_current: true,
        trusted: true,
        challenge_fresh: true,
        runtime_integrity: true,
        model_presence: ModelPresence::Ready,
        supports_vision: true,
        supports_tools: true,
        supports_media: true,
        beneficiary: Some(AccountId::new(Uuid::from_u128(0x7000 + n))),
        health: HealthState::Healthy,
        security: SecurityFence::Clear,
        data_lane_headroom: true,
        control_lane_headroom: true,
        outstanding_permits: 0,
        max_outstanding_permits: 4,
        advisory_capacity_ok: true,
        predicted_first_content: DurationMs::new(400),
        decode_tokens_per_sec: 40,
        calibration: RatioPerMille::UNIT,
    }
}

fn traits() -> RequestTraits {
    RequestTraits {
        model: ModelId::new("qwen"),
        needs_vision: false,
        needs_tools: false,
        needs_media: false,
        paid: true,
        expected_output_tokens: Tokens::new(120),
    }
}

fn candidate_strategy() -> impl Strategy<Value = CandidateSnapshot> {
    let gates = (
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
        0u8..3,
        any::<bool>(),
    );
    let capacity = (
        any::<bool>(),
        any::<bool>(),
        0u32..6,
        1u32..6,
        any::<bool>(),
        0u64..8_000,
        0u8..4,
    );
    (0u128..12, gates, capacity).prop_map(
        |(
            n,
            (session, trusted, fresh, integrity, presence, beneficiary),
            (data_lane, control_lane, outstanding, max_out, advisory, predicted, health),
        )| {
            let mut c = eligible_candidate(n);
            c.session_current = session;
            c.trusted = trusted;
            c.challenge_fresh = fresh;
            c.runtime_integrity = integrity;
            c.model_presence = match presence {
                0 => ModelPresence::NotPresent,
                1 => ModelPresence::Loading,
                _ => ModelPresence::Ready,
            };
            c.beneficiary = beneficiary.then(|| AccountId::new(Uuid::from_u128(0x7000 + n)));
            c.data_lane_headroom = data_lane;
            c.control_lane_headroom = control_lane;
            c.outstanding_permits = outstanding;
            c.max_outstanding_permits = max_out;
            c.advisory_capacity_ok = advisory;
            c.predicted_first_content = DurationMs::new(predicted);
            c.health = match health {
                0 => HealthState::Healthy,
                1 => HealthState::Suspect,
                2 => HealthState::Quarantined {
                    until: TimestampMs::new(5_000),
                },
                _ => HealthState::HalfOpen,
            };
            c
        },
    )
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1024))]

    /// Soundness: whenever `admit` says `Prepare`, the chosen candidate
    /// passes every hard gate (plan 11.2), is not excluded, and the permit
    /// expiry equals `now + ttl` (plan 9.2.10). The decision is a pure
    /// function of its inputs.
    #[test]
    fn admission_prepare_is_sound_and_deterministic(
        candidates in proptest::collection::vec(candidate_strategy(), 0..12),
        exclude_bits in any::<u16>(),
        now in 0i64..20_000,
        seed in any::<u64>(),
    ) {
        let config = AdmissionConfig::default();
        let t = traits();
        let now = TimestampMs::new(now);
        let exclude: BTreeSet<ProviderId> = candidates
            .iter()
            .enumerate()
            .filter(|(i, _)| exclude_bits & (1 << (i % 16)) != 0)
            .map(|(_, c)| c.provider)
            .collect();

        let decision = admit(&t, &candidates, &exclude, &config, now, seed);
        // Purity: identical inputs, identical decision.
        prop_assert_eq!(
            &decision,
            &admit(&t, &candidates, &exclude, &config, now, seed)
        );

        match decision {
            AdmissionDecision::Prepare(permit) => {
                let chosen = candidates
                    .iter()
                    .find(|c| c.provider == permit.provider)
                    .expect("permit names a real candidate");
                prop_assert!(!exclude.contains(&chosen.provider), "excluded provider selected");
                prop_assert!(chosen.session_current);
                prop_assert!(chosen.trusted);
                prop_assert!(chosen.challenge_fresh);
                prop_assert!(chosen.runtime_integrity);
                prop_assert!(chosen.model_presence.is_routable());
                prop_assert!(chosen.beneficiary.is_some(), "paid routing requires a beneficiary");
                prop_assert!(chosen.data_lane_headroom && chosen.control_lane_headroom);
                prop_assert!(chosen.outstanding_permits < chosen.max_outstanding_permits);
                prop_assert!(!chosen.security.is_fenced());
                prop_assert!(chosen.advisory_capacity_ok);
                if permit.is_probe {
                    prop_assert!(chosen.health.probe_eligible(now));
                } else {
                    prop_assert!(chosen.health.admits_general_traffic());
                }
                prop_assert_eq!(permit.expires_at, now.saturating_add(config.permit_ttl));
            }
            AdmissionDecision::RetryAfter { delay, .. } => {
                prop_assert!(!delay.is_zero(), "retry hint must carry a delay");
            }
            AdmissionDecision::Reject { reason } => {
                if candidates.is_empty() {
                    prop_assert_eq!(reason, RejectionReason::NoCandidates);
                }
            }
        }
    }

    /// Fail-open discipline (plan 11.6): a probe permit is issued only when
    /// no healthy warm candidate could serve the request.
    #[test]
    fn probe_only_when_no_healthy_route(
        candidates in proptest::collection::vec(candidate_strategy(), 1..12),
        now in 0i64..20_000,
        seed in any::<u64>(),
    ) {
        let config = AdmissionConfig::default();
        let t = traits();
        let now = TimestampMs::new(now);
        let exclude = BTreeSet::new();
        if let AdmissionDecision::Prepare(permit) = admit(&t, &candidates, &exclude, &config, now, seed) {
            if permit.is_probe {
                // No candidate may have been fully healthy-eligible.
                for c in &candidates {
                    let healthy_eligible = c.session_current
                        && c.trusted
                        && c.challenge_fresh
                        && c.runtime_integrity
                        && c.model_presence.is_routable()
                        && c.beneficiary.is_some()
                        && c.data_lane_headroom
                        && c.control_lane_headroom
                        && c.outstanding_permits < c.max_outstanding_permits
                        && !c.security.is_fenced()
                        && c.advisory_capacity_ok
                        && c.health.admits_general_traffic();
                    prop_assert!(
                        !healthy_eligible,
                        "probe issued while a healthy route existed"
                    );
                }
            }
        }
    }
}

/// Excluded providers are never selected — the alternate/hedge re-selection
/// guard (plan 11.1).
#[test]
fn exclusion_set_is_respected() {
    let candidates: Vec<CandidateSnapshot> = (0..4).map(eligible_candidate).collect();
    let all: BTreeSet<ProviderId> = candidates.iter().map(|c| c.provider).collect();
    let config = AdmissionConfig::default();
    let now = TimestampMs::new(0);
    for seed in 0..8 {
        match admit(&traits(), &candidates, &all, &config, now, seed) {
            AdmissionDecision::Prepare(_) => panic!("selected an excluded provider"),
            AdmissionDecision::RetryAfter { .. } | AdmissionDecision::Reject { .. } => {}
        }
    }
}
