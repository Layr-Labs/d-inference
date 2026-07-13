use darkbloom_coordinator_core::{
    deadline::{DurationMillis, EpochMillis},
    fleet::{
        AdmissionError, AdmissionKind, CalibrationBook, CalibrationError, CalibrationEvent,
        CalibrationKey, CalibrationPolicy, CalibrationValue, CapacitySnapshot, FleetEvent,
        FleetSnapshot, FleetStateError, FleetUpdate, HealthError, HealthEvent, HealthMode,
        HealthPolicy, HealthState, ProviderSnapshot, admit, reduce_calibration, reduce_fleet,
        reduce_health,
    },
    ids::{
        CalibrationRevision, FleetRevision, HardwareClass, ModelId, ModelRevision, PermitId,
        ProviderId, SessionId, SessionRevision, TrustRevision,
    },
    request::ProviderFence,
    tokens::{KvBytes, TokenCount},
    traits::{Capability, ProviderTraits, RequestTraits},
};
use proptest::prelude::*;
use uuid::Uuid;

fn revision(value: u64) -> FleetRevision {
    FleetRevision::new(value).expect("nonzero fleet revision")
}

fn calibration_revision(value: u64) -> CalibrationRevision {
    CalibrationRevision::new(value).expect("nonzero calibration revision")
}

fn permit(value: u128) -> PermitId {
    PermitId::new(Uuid::from_u128(value)).expect("nonzero permit")
}

fn fence(value: u128) -> ProviderFence {
    ProviderFence {
        provider_id: ProviderId::new(Uuid::from_u128(value)).expect("nonzero provider"),
        session_id: SessionId::new(Uuid::from_u128(value + 100)).expect("nonzero session"),
        session_revision: SessionRevision::new(1).expect("nonzero"),
        trust_revision: TrustRevision::new(1).expect("nonzero"),
        model_id: ModelId::new("model/test").expect("valid"),
        model_revision: ModelRevision::new(1).expect("nonzero"),
    }
}

fn provider_with(capacity: CapacitySnapshot, health: HealthState) -> ProviderSnapshot {
    ProviderSnapshot::new(
        fence(1),
        HardwareClass::new("m4-max").expect("valid"),
        ProviderTraits::new(TokenCount::new(8_192), [Capability::Tools], true),
        capacity,
        health,
    )
}

fn capacity() -> CapacitySnapshot {
    CapacitySnapshot::new(
        TokenCount::new(100),
        TokenCount::new(20),
        KvBytes::new(1_000),
        KvBytes::new(200),
        2,
        1,
    )
    .expect("valid capacity")
}

#[test]
fn admission_checks_traits_tokens_kv_and_concurrency_independently() {
    let provider = provider_with(capacity(), HealthState::new());
    let request = RequestTraits::new(TokenCount::new(30)).requiring(Capability::Tools);

    let admitted = admit(
        &provider,
        &request,
        darkbloom_coordinator_core::fleet::AdmissionDemand::new(
            TokenCount::new(10),
            TokenCount::new(20),
            KvBytes::new(300),
        )
        .expect("valid demand"),
        AdmissionKind::Regular,
    )
    .expect("fits");
    assert_eq!(
        admitted.projected_capacity.tokens_in_use(),
        TokenCount::new(50)
    );
    assert_eq!(admitted.projected_capacity.kv_in_use(), KvBytes::new(500));
    assert_eq!(admitted.projected_capacity.concurrency_in_use(), 2);

    let token_rejection = admit(
        &provider,
        &RequestTraits::new(TokenCount::new(81)).requiring(Capability::Tools),
        darkbloom_coordinator_core::fleet::AdmissionDemand::new(
            TokenCount::new(70),
            TokenCount::new(11),
            KvBytes::ZERO,
        )
        .expect("valid demand"),
        AdmissionKind::Regular,
    );
    assert!(matches!(
        token_rejection,
        Err(AdmissionError::TokenBudgetExceeded { .. })
    ));

    let kv_rejection = admit(
        &provider,
        &RequestTraits::new(TokenCount::ZERO).requiring(Capability::Tools),
        darkbloom_coordinator_core::fleet::AdmissionDemand::new(
            TokenCount::ZERO,
            TokenCount::ZERO,
            KvBytes::new(801),
        )
        .expect("valid demand"),
        AdmissionKind::Regular,
    );
    assert!(matches!(
        kv_rejection,
        Err(AdmissionError::KvBudgetExceeded { .. })
    ));

    let full = provider_with(
        CapacitySnapshot::new(
            TokenCount::new(100),
            TokenCount::ZERO,
            KvBytes::new(1_000),
            KvBytes::ZERO,
            1,
            1,
        )
        .expect("valid"),
        HealthState::new(),
    );
    assert!(matches!(
        admit(
            &full,
            &RequestTraits::new(TokenCount::ZERO),
            darkbloom_coordinator_core::fleet::AdmissionDemand::new(
                TokenCount::ZERO,
                TokenCount::ZERO,
                KvBytes::ZERO,
            )
            .expect("valid"),
            AdmissionKind::Regular,
        ),
        Err(AdmissionError::ConcurrencyExceeded { .. })
    ));
}

#[test]
fn admission_rejects_context_count_mismatch_before_provider_checks() {
    let provider = ProviderSnapshot::new(
        fence(1),
        HardwareClass::new("m4-max").expect("valid"),
        ProviderTraits::new(TokenCount::new(1), [], false),
        capacity(),
        HealthState::new(),
    );
    let demand = darkbloom_coordinator_core::fleet::AdmissionDemand::new(
        TokenCount::new(10),
        TokenCount::new(20),
        KvBytes::ZERO,
    )
    .expect("valid demand");
    assert_eq!(
        admit(
            &provider,
            &RequestTraits::new(TokenCount::new(29)),
            demand,
            AdmissionKind::Regular,
        ),
        Err(AdmissionError::ContextTokenMismatch {
            traits: TokenCount::new(29),
            demand: TokenCount::new(30),
        })
    );
}

#[test]
fn fleet_reducer_rejects_stale_global_and_provider_revisions() {
    let initial = FleetSnapshot::new(revision(1));
    let provider = provider_with(capacity(), HealthState::new());
    let populated = reduce_fleet(
        &initial,
        FleetEvent {
            revision: revision(2),
            update: FleetUpdate::Upsert(Box::new(provider.clone())),
        },
    )
    .expect("fresh insert");
    assert!(initial.provider(provider.fence().provider_id).is_none());
    assert!(populated.provider(provider.fence().provider_id).is_some());

    assert_eq!(
        reduce_fleet(
            &populated,
            FleetEvent {
                revision: revision(2),
                update: FleetUpdate::Upsert(Box::new(provider.clone())),
            },
        ),
        Err(FleetStateError::StaleFleetRevision {
            current: revision(2),
            supplied: revision(2),
        })
    );

    let mut stale_fence = provider.fence().clone();
    stale_fence.session_id = SessionId::new(Uuid::from_u128(999)).expect("nonzero");
    let stale = ProviderSnapshot::new(
        stale_fence,
        provider.hardware().clone(),
        provider.traits().clone(),
        provider.capacity(),
        provider.health(),
    );
    assert_eq!(
        reduce_fleet(
            &populated,
            FleetEvent {
                revision: revision(3),
                update: FleetUpdate::Upsert(Box::new(stale)),
            },
        ),
        Err(FleetStateError::StaleProviderRevision {
            provider_id: provider.fence().provider_id,
        })
    );
}

#[test]
fn removed_provider_tombstone_blocks_delayed_session_resurrection() {
    let initial = FleetSnapshot::new(revision(1));
    let provider = provider_with(capacity(), HealthState::new());
    let provider_id = provider.fence().provider_id;
    let populated = reduce_fleet(
        &initial,
        FleetEvent {
            revision: revision(2),
            update: FleetUpdate::Upsert(Box::new(provider.clone())),
        },
    )
    .expect("insert");
    let removed = reduce_fleet(
        &populated,
        FleetEvent {
            revision: revision(3),
            update: FleetUpdate::Remove {
                provider_id,
                expected_session_revision: provider.fence().session_revision,
            },
        },
    )
    .expect("remove");

    assert!(removed.provider(provider_id).is_none());
    let tombstone = removed.tombstone(provider_id).expect("retained fence");
    assert_eq!(tombstone.removed_at_revision(), revision(3));
    assert_eq!(tombstone.fence(), provider.fence());

    assert_eq!(
        reduce_fleet(
            &removed,
            FleetEvent {
                revision: revision(4),
                update: FleetUpdate::Upsert(Box::new(provider.clone())),
            },
        ),
        Err(FleetStateError::RemovedSessionRevision {
            provider_id,
            removed_at: revision(3),
        })
    );
    assert!(removed.tombstone(provider_id).is_some());

    let mut next_fence = provider.fence().clone();
    next_fence.session_id = SessionId::new(Uuid::from_u128(1_001)).expect("nonzero");
    next_fence.session_revision = SessionRevision::new(2).expect("nonzero");
    let next_provider = ProviderSnapshot::new(
        next_fence,
        provider.hardware().clone(),
        provider.traits().clone(),
        provider.capacity(),
        provider.health(),
    );
    let resurrected = reduce_fleet(
        &removed,
        FleetEvent {
            revision: revision(4),
            update: FleetUpdate::Upsert(Box::new(next_provider)),
        },
    )
    .expect("strictly newer session");
    assert!(resurrected.provider(provider_id).is_some());
    assert!(resurrected.tombstone(provider_id).is_none());
}

#[test]
fn health_cooldown_boundary_and_probe_identity_are_exact() {
    let policy = HealthPolicy::new(
        1,
        DurationMillis::new(10).expect("nonzero duration"),
        DurationMillis::new(5).expect("nonzero probe timeout"),
    )
    .expect("valid policy");
    let open = reduce_health(
        HealthState::new(),
        HealthEvent::Failure {
            now: EpochMillis::new(5),
        },
        policy,
    )
    .expect("opens");
    assert!(matches!(
        reduce_health(
            open,
            HealthEvent::Tick {
                now: EpochMillis::new(14)
            },
            policy,
        )
        .expect("early tick")
        .mode(),
        HealthMode::Open { .. }
    ));
    let half_open = reduce_health(
        open,
        HealthEvent::Tick {
            now: EpochMillis::new(15),
        },
        policy,
    )
    .expect("boundary half-opens");
    let in_flight = reduce_health(
        half_open,
        HealthEvent::ProbeAcquired {
            now: EpochMillis::new(15),
            permit_id: permit(1),
        },
        policy,
    )
    .expect("one probe");
    assert!(matches!(
        reduce_health(
            in_flight,
            HealthEvent::ProbeSucceeded {
                now: EpochMillis::new(16),
                permit_id: permit(2),
            },
            policy,
        ),
        Err(HealthError::ProbePermitMismatch { .. })
    ));
    let reopened = reduce_health(
        in_flight,
        HealthEvent::ProbeFailed {
            now: EpochMillis::new(16),
            permit_id: permit(1),
        },
        policy,
    )
    .expect("matching failure");
    assert!(matches!(reopened.mode(), HealthMode::Open { .. }));
    assert_eq!(
        reduce_health(
            reopened,
            HealthEvent::Tick {
                now: EpochMillis::new(15),
            },
            policy,
        ),
        Err(HealthError::ObservationTimeRegressed)
    );
}

#[test]
fn half_open_tick_reclaims_expired_dropped_probe() {
    let policy = HealthPolicy::new(
        1,
        DurationMillis::new(10).expect("nonzero open duration"),
        DurationMillis::new(3).expect("nonzero probe timeout"),
    )
    .expect("valid");
    let open = reduce_health(
        HealthState::new(),
        HealthEvent::Failure {
            now: EpochMillis::new(1),
        },
        policy,
    )
    .expect("open");
    let half_open = reduce_health(
        open,
        HealthEvent::Tick {
            now: EpochMillis::new(11),
        },
        policy,
    )
    .expect("half-open");
    let claimed = reduce_health(
        half_open,
        HealthEvent::ProbeAcquired {
            now: EpochMillis::new(11),
            permit_id: permit(1),
        },
        policy,
    )
    .expect("claim");
    match claimed.mode() {
        HealthMode::HalfOpen { probe: Some(claim) } => {
            assert_eq!(claim.permit_id(), permit(1));
            assert_eq!(claim.expires_at(), EpochMillis::new(14));
        }
        mode => panic!("unexpected mode {mode:?}"),
    }

    let before_expiry = reduce_health(
        claimed,
        HealthEvent::Tick {
            now: EpochMillis::new(13),
        },
        policy,
    )
    .expect("unexpired tick");
    assert!(matches!(
        before_expiry.mode(),
        HealthMode::HalfOpen { probe: Some(_) }
    ));
    assert_eq!(
        reduce_health(
            claimed,
            HealthEvent::ProbeSucceeded {
                now: EpochMillis::new(14),
                permit_id: permit(1),
            },
            policy,
        ),
        Err(HealthError::ProbeExpired)
    );

    let reclaimed = reduce_health(
        claimed,
        HealthEvent::Tick {
            now: EpochMillis::new(14),
        },
        policy,
    )
    .expect("expiry tick");
    assert!(matches!(
        reclaimed.mode(),
        HealthMode::HalfOpen { probe: None }
    ));
    let replacement = reduce_health(
        reclaimed,
        HealthEvent::ProbeAcquired {
            now: EpochMillis::new(14),
            permit_id: permit(2),
        },
        policy,
    )
    .expect("replacement probe");
    assert_eq!(
        reduce_health(
            replacement,
            HealthEvent::ProbeSucceeded {
                now: EpochMillis::new(15),
                permit_id: permit(1),
            },
            policy,
        ),
        Err(HealthError::ProbePermitMismatch {
            expected: permit(2),
            supplied: permit(1),
        })
    );
}

#[test]
fn only_the_claimed_half_open_probe_can_be_admitted() {
    let policy = HealthPolicy::new(
        1,
        DurationMillis::new(1).expect("nonzero duration"),
        DurationMillis::new(5).expect("nonzero probe timeout"),
    )
    .expect("valid");
    let open = reduce_health(
        HealthState::new(),
        HealthEvent::Failure {
            now: EpochMillis::new(1),
        },
        policy,
    )
    .expect("open");
    let half_open = reduce_health(
        open,
        HealthEvent::Tick {
            now: EpochMillis::new(2),
        },
        policy,
    )
    .expect("half-open");
    let in_flight = reduce_health(
        half_open,
        HealthEvent::ProbeAcquired {
            now: EpochMillis::new(2),
            permit_id: permit(1),
        },
        policy,
    )
    .expect("probe");
    let provider = provider_with(capacity(), in_flight);
    let demand = darkbloom_coordinator_core::fleet::AdmissionDemand::new(
        TokenCount::new(1),
        TokenCount::new(1),
        KvBytes::new(1),
    )
    .expect("valid");

    assert!(matches!(
        admit(
            &provider,
            &RequestTraits::new(TokenCount::new(2)),
            demand,
            AdmissionKind::Regular,
        ),
        Err(AdmissionError::ProviderUnhealthy)
    ));
    assert!(matches!(
        admit(
            &provider,
            &RequestTraits::new(TokenCount::new(2)),
            demand,
            AdmissionKind::Probe(permit(2)),
        ),
        Err(AdmissionError::ProbePermitMismatch)
    ));
    assert!(
        admit(
            &provider,
            &RequestTraits::new(TokenCount::new(2)),
            demand,
            AdmissionKind::Probe(permit(1)),
        )
        .is_ok()
    );
}

#[test]
fn calibration_is_keyed_waits_for_samples_and_uses_even_median() {
    let policy = CalibrationPolicy::new(
        4,
        4,
        CalibrationValue::new(1).expect("positive"),
        CalibrationValue::new(1_000).expect("positive"),
    )
    .expect("valid");
    let key = CalibrationKey {
        model_id: ModelId::new("model/a").expect("valid"),
        hardware: HardwareClass::new("m4").expect("valid"),
    };
    let other = CalibrationKey {
        model_id: ModelId::new("model/a").expect("valid"),
        hardware: HardwareClass::new("m3").expect("valid"),
    };
    let mut book = CalibrationBook::new(calibration_revision(1), policy);
    for (revision_value, value) in [(2, 10), (3, 20), (4, 30)] {
        book = reduce_calibration(
            &book,
            CalibrationEvent {
                revision: calibration_revision(revision_value),
                key: key.clone(),
                value: CalibrationValue::new(value).expect("positive"),
            },
        )
        .expect("fresh");
    }
    assert_eq!(book.estimate(&key), None);
    book = reduce_calibration(
        &book,
        CalibrationEvent {
            revision: calibration_revision(5),
            key: key.clone(),
            value: CalibrationValue::new(100).expect("positive"),
        },
    )
    .expect("fourth");
    let estimate = book.estimate(&key).expect("ready");
    assert_eq!(estimate.raw_median.get(), 25);
    assert_eq!(book.estimate(&other), None);
    assert_eq!(
        reduce_calibration(
            &book,
            CalibrationEvent {
                revision: calibration_revision(4),
                key,
                value: CalibrationValue::new(10).expect("positive"),
            },
        ),
        Err(CalibrationError::StaleRevision {
            current: calibration_revision(5),
            supplied: calibration_revision(4),
        })
    );
}

proptest! {
    #[test]
    fn successful_admission_never_exceeds_any_capacity(
        token_capacity in 1_u64..1_000_000,
        raw_tokens_in_use in 0_u64..1_000_000,
        requested_tokens in 0_u64..1_000_000,
        kv_capacity in 1_u64..1_000_000,
        raw_kv_in_use in 0_u64..1_000_000,
        requested_kv in 0_u64..1_000_000,
        concurrency_limit in 1_u32..100,
        raw_concurrency_in_use in 0_u32..100,
    ) {
        let tokens_in_use = raw_tokens_in_use % (token_capacity + 1);
        let kv_in_use = raw_kv_in_use % (kv_capacity + 1);
        let concurrency_in_use = raw_concurrency_in_use % (concurrency_limit + 1);
        let capacity = CapacitySnapshot::new(
            TokenCount::new(token_capacity),
            TokenCount::new(tokens_in_use),
            KvBytes::new(kv_capacity),
            KvBytes::new(kv_in_use),
            concurrency_limit,
            concurrency_in_use,
        ).expect("assumptions make valid");
        let provider = provider_with(capacity, HealthState::new());
        let demand = darkbloom_coordinator_core::fleet::AdmissionDemand::new(
            TokenCount::new(requested_tokens),
            TokenCount::ZERO,
            KvBytes::new(requested_kv),
        ).expect("single token component cannot overflow");
        if let Ok(admission) = admit(
            &provider,
            &RequestTraits::new(TokenCount::new(requested_tokens)),
            demand,
            AdmissionKind::Regular,
        ) {
            prop_assert!(
                admission.projected_capacity.tokens_in_use()
                    <= admission.projected_capacity.token_capacity()
            );
            prop_assert!(
                admission.projected_capacity.kv_in_use()
                    <= admission.projected_capacity.kv_capacity()
            );
            prop_assert!(
                admission.projected_capacity.concurrency_in_use()
                    <= admission.projected_capacity.concurrency_limit()
            );
        }
    }

    #[test]
    fn every_context_token_mismatch_is_rejected_before_capacity(
        prompt in 0_u64..10_000,
        completion in 0_u64..10_000,
    ) {
        let total = prompt + completion;
        let wrong = total + 1;
        let provider = provider_with(
            CapacitySnapshot::new(
                TokenCount::new(100_000),
                TokenCount::ZERO,
                KvBytes::new(100_000),
                KvBytes::ZERO,
                8,
                0,
            ).expect("valid"),
            HealthState::new(),
        );
        let demand = darkbloom_coordinator_core::fleet::AdmissionDemand::new(
            TokenCount::new(prompt),
            TokenCount::new(completion),
            KvBytes::ZERO,
        ).expect("bounded sum");
        prop_assert_eq!(
            admit(
                &provider,
                &RequestTraits::new(TokenCount::new(wrong)),
                demand,
                AdmissionKind::Regular,
            ),
            Err(AdmissionError::ContextTokenMismatch {
                traits: TokenCount::new(wrong),
                demand: TokenCount::new(total),
            })
        );
    }
}
