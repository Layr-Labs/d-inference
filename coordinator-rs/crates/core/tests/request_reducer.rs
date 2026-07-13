use darkbloom_coordinator_core::{
    deadline::{AbsoluteDeadline, EpochMillis},
    ids::{
        AttemptId, Digest, EventId, FundingId, LeaseId, ModelId, ModelRevision, PermitId,
        ProviderId, RequestId, SessionId, SessionRevision, TrustRevision,
    },
    money::MicroUsd,
    request::{
        ApplyOutcome, AttemptKind, AttemptReleaseReason, AttemptStatus, ProviderFence,
        RecordedRequestEvent, RequestContext, RequestError, RequestEvent, RequestState, reduce,
    },
    terminal::{ReviewReason, TerminalDisposition},
};
use proptest::prelude::*;
use uuid::Uuid;

fn request_id(value: u128) -> RequestId {
    RequestId::new(Uuid::from_u128(value)).expect("nonzero request ID")
}

fn attempt_id(value: u128) -> AttemptId {
    AttemptId::new(Uuid::from_u128(value)).expect("nonzero attempt ID")
}

fn event_id(value: u128) -> EventId {
    EventId::new(Uuid::from_u128(value)).expect("nonzero event ID")
}

fn funding_id(value: u128) -> FundingId {
    FundingId::new(Uuid::from_u128(value)).expect("nonzero funding ID")
}

fn lease_id(value: u128) -> LeaseId {
    LeaseId::new(Uuid::from_u128(value)).expect("nonzero lease ID")
}

fn permit_id(value: u128) -> PermitId {
    PermitId::new(Uuid::from_u128(value)).expect("nonzero permit ID")
}

fn provider_fence(value: u128) -> ProviderFence {
    ProviderFence {
        provider_id: ProviderId::new(Uuid::from_u128(value)).expect("nonzero provider ID"),
        session_id: SessionId::new(Uuid::from_u128(value + 100)).expect("nonzero session ID"),
        session_revision: SessionRevision::new(1).expect("nonzero revision"),
        trust_revision: TrustRevision::new(1).expect("nonzero revision"),
        model_id: ModelId::new("model/test").expect("valid model ID"),
        model_revision: ModelRevision::new(1).expect("nonzero revision"),
    }
}

fn context(now: u64, fences: &[ProviderFence]) -> RequestContext {
    fences.iter().cloned().fold(
        RequestContext::new(EpochMillis::new(now)),
        |context, fence| context.with_provider(fence),
    )
}

fn recorded(seed: u8, payload: RequestEvent) -> RecordedRequestEvent {
    RecordedRequestEvent {
        id: event_id(u128::from(seed) + 1_000),
        digest: Digest::new([seed; 32]),
        payload,
    }
}

fn apply(
    state: &mut RequestState,
    seed: u8,
    payload: RequestEvent,
    context: &RequestContext,
) -> Result<ApplyOutcome, RequestError> {
    let reduction = reduce(state, &recorded(seed, payload), context)?;
    *state = reduction.state;
    Ok(reduction.outcome)
}

fn funded_state(fence: &ProviderFence) -> RequestState {
    let mut state = RequestState::new(
        request_id(1),
        AbsoluteDeadline::new(1_000).expect("valid deadline"),
    );
    apply(
        &mut state,
        1,
        RequestEvent::FundsReserved {
            funding_id: funding_id(1),
            amount: MicroUsd::new(100),
        },
        &context(1, std::slice::from_ref(fence)),
    )
    .expect("funding");
    state
}

fn prepare(
    state: &mut RequestState,
    seed: u8,
    attempt: u128,
    kind: AttemptKind,
    fence: &ProviderFence,
    now: u64,
) -> Result<ApplyOutcome, RequestError> {
    apply(
        state,
        seed,
        RequestEvent::AttemptPrepared {
            attempt_id: attempt_id(attempt),
            kind,
            provider: fence.clone(),
            lease_id: lease_id(attempt + 100),
            permit_id: permit_id(attempt + 200),
        },
        &context(now, std::slice::from_ref(fence)),
    )
}

#[test]
fn legal_hedge_trace_conserves_every_lease_and_permit() {
    let primary = provider_fence(10);
    let hedge = provider_fence(20);
    let all = [primary.clone(), hedge.clone()];
    let mut state = funded_state(&primary);

    prepare(&mut state, 2, 10, AttemptKind::Primary, &primary, 2).expect("primary");
    apply(
        &mut state,
        3,
        RequestEvent::AttemptPrepared {
            attempt_id: attempt_id(20),
            kind: AttemptKind::Hedge,
            provider: hedge.clone(),
            lease_id: lease_id(120),
            permit_id: permit_id(220),
        },
        &context(3, &all),
    )
    .expect("hedge");
    apply(
        &mut state,
        4,
        RequestEvent::StartAuthorized {
            attempt_id: attempt_id(20),
            provider: hedge.clone(),
        },
        &context(4, &all),
    )
    .expect("authorization");

    assert_eq!(state.authorized_attempt(), Some(attempt_id(20)));
    assert!(matches!(
        state.attempt(attempt_id(10)).expect("primary").status(),
        AttemptStatus::Released {
            reason: AttemptReleaseReason::NotSelected
        }
    ));
    assert_eq!(state.resources().active_leases().expect("valid"), 1);
    assert_eq!(state.resources().active_permits().expect("valid"), 1);

    apply(
        &mut state,
        5,
        RequestEvent::FirstContent {
            attempt_id: attempt_id(20),
            provider: hedge,
        },
        &context(5, &all),
    )
    .expect("first content");
    apply(
        &mut state,
        6,
        RequestEvent::Terminated {
            disposition: TerminalDisposition::Settled {
                charged: MicroUsd::new(80),
            },
        },
        &context(6, &all),
    )
    .expect("settlement");

    assert_eq!(
        state.terminal(),
        Some(TerminalDisposition::Settled {
            charged: MicroUsd::new(80)
        })
    );
    assert_eq!(state.resources().acquired_leases(), 2);
    assert_eq!(state.resources().released_leases(), 2);
    assert_eq!(state.resources().acquired_permits(), 2);
    assert_eq!(state.resources().released_permits(), 2);
    state.validate_invariants().expect("all invariants");
}

#[test]
fn authorized_precontent_failure_releases_primary_and_allows_one_alternate() {
    let primary = provider_fence(10);
    let alternate = provider_fence(20);
    let all = [primary.clone(), alternate.clone()];
    let mut state = funded_state(&primary);
    prepare(&mut state, 2, 10, AttemptKind::Primary, &primary, 2).expect("primary");
    apply(
        &mut state,
        3,
        RequestEvent::StartAuthorized {
            attempt_id: attempt_id(10),
            provider: primary,
        },
        &context(3, &all),
    )
    .expect("authorize primary");
    apply(
        &mut state,
        4,
        RequestEvent::PreContentFailed {
            attempt_id: attempt_id(10),
        },
        &context(4, &all),
    )
    .expect("release uncommitted primary");
    assert_eq!(state.authorized_attempt(), None);
    assert!(!state.has_first_content());
    assert!(matches!(
        state.attempt(attempt_id(10)).expect("primary").status(),
        AttemptStatus::Released {
            reason: AttemptReleaseReason::PreContentFailure
        }
    ));
    assert_eq!(state.resources().active_leases().expect("valid"), 0);

    prepare(&mut state, 5, 20, AttemptKind::Alternate, &alternate, 5).expect("sole alternate");
    apply(
        &mut state,
        6,
        RequestEvent::StartAuthorized {
            attempt_id: attempt_id(20),
            provider: alternate.clone(),
        },
        &context(6, &all),
    )
    .expect("authorize alternate");
    apply(
        &mut state,
        7,
        RequestEvent::FirstContent {
            attempt_id: attempt_id(20),
            provider: alternate,
        },
        &context(7, &all),
    )
    .expect("alternate content");
    assert!(state.has_first_content());
    state.validate_invariants().expect("valid failover state");
}

#[test]
fn invalid_transition_table_is_rejected_transactionally() {
    let fence = provider_fence(10);
    let deadline = AbsoluteDeadline::new(100).expect("valid");

    let empty = RequestState::new(request_id(2), deadline);
    let cases = [
        (
            "work before funding",
            empty.clone(),
            RequestEvent::AttemptPrepared {
                attempt_id: attempt_id(1),
                kind: AttemptKind::Primary,
                provider: fence.clone(),
                lease_id: lease_id(1),
                permit_id: permit_id(1),
            },
            RequestError::FundingRequired,
        ),
        (
            "deadline reset",
            empty,
            RequestEvent::DeadlineAsserted {
                deadline: AbsoluteDeadline::new(101).expect("valid"),
            },
            RequestError::DeadlineMismatch {
                fixed: deadline,
                supplied: AbsoluteDeadline::new(101).expect("valid"),
            },
        ),
    ];

    for (name, state, payload, expected) in cases {
        let before = state.clone();
        assert_eq!(
            reduce(
                &state,
                &recorded(90, payload),
                &context(1, std::slice::from_ref(&fence))
            ),
            Err(expected),
            "{name}"
        );
        assert_eq!(state, before, "{name} mutated rejected input");
    }

    let mut funded = funded_state(&fence);
    let before = funded.clone();
    assert_eq!(
        apply(
            &mut funded,
            2,
            RequestEvent::FundsReserved {
                funding_id: funding_id(2),
                amount: MicroUsd::new(100),
            },
            &context(2, &[fence]),
        ),
        Err(RequestError::FundingAlreadyReserved)
    );
    assert_eq!(funded, before);
}

#[test]
fn alternates_hedges_and_failover_are_strictly_bounded() {
    let fence = provider_fence(10);
    let mut state = funded_state(&fence);
    prepare(&mut state, 2, 10, AttemptKind::Primary, &fence, 2).expect("primary");

    let alternate_before_release = prepare(&mut state, 3, 20, AttemptKind::Alternate, &fence, 3);
    assert_eq!(
        alternate_before_release,
        Err(RequestError::AlternateBeforePrimaryReleased)
    );

    prepare(&mut state, 4, 30, AttemptKind::Hedge, &fence, 4).expect("one hedge");
    assert_eq!(
        prepare(&mut state, 5, 31, AttemptKind::Hedge, &fence, 5),
        Err(RequestError::HedgeAlreadyPrepared)
    );
    apply(
        &mut state,
        6,
        RequestEvent::StartAuthorized {
            attempt_id: attempt_id(10),
            provider: fence.clone(),
        },
        &context(6, std::slice::from_ref(&fence)),
    )
    .expect("authorize primary");

    let before = state.clone();
    assert_eq!(
        prepare(&mut state, 7, 40, AttemptKind::Alternate, &fence, 7),
        Err(RequestError::FailoverAfterAuthorization)
    );
    assert_eq!(state, before);
    assert_eq!(
        apply(
            &mut state,
            8,
            RequestEvent::AttemptReleased {
                attempt_id: attempt_id(10),
                reason: AttemptReleaseReason::PreAuthorizationFailure,
            },
            &context(8, &[fence]),
        ),
        Err(RequestError::FailoverAfterAuthorization)
    );
}

#[test]
fn stale_session_trust_and_model_revisions_are_all_rejected() {
    let current = provider_fence(10);
    let mut stale_values = Vec::new();

    let mut stale_session = current.clone();
    stale_session.session_id =
        SessionId::new(Uuid::from_u128(999)).expect("nonzero stale session ID");
    stale_values.push(stale_session);

    let mut stale_trust = current.clone();
    stale_trust.trust_revision = TrustRevision::new(2).expect("nonzero");
    stale_values.push(stale_trust);

    let mut stale_model = current.clone();
    stale_model.model_revision = ModelRevision::new(2).expect("nonzero");
    stale_values.push(stale_model);

    for (index, stale) in stale_values.into_iter().enumerate() {
        let state = funded_state(&current);
        let result = reduce(
            &state,
            &recorded(
                u8::try_from(index + 20).expect("small index"),
                RequestEvent::AttemptPrepared {
                    attempt_id: attempt_id(50 + index as u128),
                    kind: AttemptKind::Primary,
                    provider: stale,
                    lease_id: lease_id(50 + index as u128),
                    permit_id: permit_id(50 + index as u128),
                },
            ),
            &context(2, std::slice::from_ref(&current)),
        );
        assert_eq!(
            result,
            Err(RequestError::StaleProviderFence {
                provider_id: current.provider_id
            })
        );
    }
}

#[test]
fn replay_identity_is_deterministic_and_conflicts_are_rejected() {
    let fence = provider_fence(10);
    let state = RequestState::new(request_id(3), AbsoluteDeadline::new(100).expect("valid"));
    let original = recorded(
        1,
        RequestEvent::FundsReserved {
            funding_id: funding_id(1),
            amount: MicroUsd::new(10),
        },
    );
    let applied =
        reduce(&state, &original, &context(1, std::slice::from_ref(&fence))).expect("applied");
    assert_eq!(applied.outcome, ApplyOutcome::Applied);

    let duplicate = reduce(
        &applied.state,
        &original,
        &context(2, std::slice::from_ref(&fence)),
    )
    .expect("duplicate");
    assert_eq!(duplicate.outcome, ApplyOutcome::Duplicate);
    assert_eq!(duplicate.state, applied.state);

    let same_digest_alias = RecordedRequestEvent {
        id: event_id(9_999),
        ..original.clone()
    };
    assert_eq!(
        reduce(
            &applied.state,
            &same_digest_alias,
            &context(2, std::slice::from_ref(&fence))
        )
        .expect("digest alias")
        .outcome,
        ApplyOutcome::Duplicate
    );

    let conflicting_id = RecordedRequestEvent {
        digest: Digest::new([2; 32]),
        ..original.clone()
    };
    assert!(matches!(
        reduce(
            &applied.state,
            &conflicting_id,
            &context(2, std::slice::from_ref(&fence))
        ),
        Err(RequestError::EventReplayConflict { .. })
    ));

    let conflicting_digest = RecordedRequestEvent {
        id: event_id(9_998),
        digest: original.digest,
        payload: RequestEvent::DeadlineAsserted {
            deadline: applied.state.deadline(),
        },
    };
    assert_eq!(
        reduce(&applied.state, &conflicting_digest, &context(2, &[fence])),
        Err(RequestError::DigestReplayConflict {
            digest: original.digest
        })
    );
}

#[test]
fn terminal_dispositions_are_mutually_exclusive_and_exactly_once() {
    for (index, disposition) in [
        TerminalDisposition::Released,
        TerminalDisposition::ReviewPending {
            reason: ReviewReason::AmbiguousProviderOutcome,
        },
    ]
    .into_iter()
    .enumerate()
    {
        let fence = provider_fence(100 + index as u128);
        let mut state = funded_state(&fence);
        apply(
            &mut state,
            50,
            RequestEvent::Terminated { disposition },
            &context(2, std::slice::from_ref(&fence)),
        )
        .expect("terminal");
        assert_eq!(state.terminal(), Some(disposition));
        assert_eq!(
            apply(
                &mut state,
                51,
                RequestEvent::Terminated {
                    disposition: TerminalDisposition::Released,
                },
                &context(3, &[fence]),
            ),
            Err(RequestError::EventAfterTerminal)
        );
    }
}

#[test]
fn cancellation_is_only_an_atomic_terminal_release_before_or_after_authorization() {
    let fence = provider_fence(10);
    let mut before_authorization = funded_state(&fence);
    prepare(
        &mut before_authorization,
        2,
        10,
        AttemptKind::Primary,
        &fence,
        2,
    )
    .expect("primary");
    prepare(
        &mut before_authorization,
        3,
        20,
        AttemptKind::Hedge,
        &fence,
        3,
    )
    .expect("hedge");
    assert_eq!(
        apply(
            &mut before_authorization,
            4,
            RequestEvent::AttemptReleased {
                attempt_id: attempt_id(10),
                reason: AttemptReleaseReason::Cancelled,
            },
            &context(4, std::slice::from_ref(&fence)),
        ),
        Err(RequestError::CancellationRequiresTerminal)
    );
    assert_eq!(
        prepare(
            &mut before_authorization,
            5,
            30,
            AttemptKind::Alternate,
            &fence,
            5,
        ),
        Err(RequestError::AlternateBeforePrimaryReleased)
    );
    apply(
        &mut before_authorization,
        6,
        RequestEvent::Terminated {
            disposition: TerminalDisposition::Released,
        },
        &context(6, std::slice::from_ref(&fence)),
    )
    .expect("atomic pre-authorization cancellation");
    assert_eq!(
        before_authorization
            .resources()
            .active_permits()
            .expect("valid"),
        0
    );
    assert_eq!(
        before_authorization
            .resources()
            .active_leases()
            .expect("valid"),
        0
    );

    let mut after_authorization = funded_state(&fence);
    prepare(
        &mut after_authorization,
        10,
        40,
        AttemptKind::Primary,
        &fence,
        2,
    )
    .expect("primary");
    apply(
        &mut after_authorization,
        11,
        RequestEvent::StartAuthorized {
            attempt_id: attempt_id(40),
            provider: fence.clone(),
        },
        &context(3, std::slice::from_ref(&fence)),
    )
    .expect("authorization");
    assert_eq!(
        apply(
            &mut after_authorization,
            12,
            RequestEvent::AttemptReleased {
                attempt_id: attempt_id(40),
                reason: AttemptReleaseReason::Cancelled,
            },
            &context(4, std::slice::from_ref(&fence)),
        ),
        Err(RequestError::CancellationRequiresTerminal)
    );
    apply(
        &mut after_authorization,
        13,
        RequestEvent::Terminated {
            disposition: TerminalDisposition::Released,
        },
        &context(5, std::slice::from_ref(&fence)),
    )
    .expect("atomic post-authorization cancellation");
    assert_eq!(
        after_authorization
            .resources()
            .active_permits()
            .expect("valid"),
        0
    );
    assert_eq!(
        after_authorization
            .resources()
            .active_leases()
            .expect("valid"),
        0
    );
}

proptest! {
    #[test]
    fn arbitrary_invalid_traces_preserve_all_request_invariants(
        operations in prop::collection::vec(0_u8..=12, 1..100)
    ) {
        let fence = provider_fence(10);
        let deadline = AbsoluteDeadline::new(1_000).expect("valid");
        let mut state = RequestState::new(request_id(500), deadline);
        let mut successful_terminals = 0_u8;

        for (index, operation) in operations.into_iter().enumerate() {
            let attempt = attempt_id(u128::from(operation % 3) + 1);
            let payload = match operation {
                0 => RequestEvent::FundsReserved {
                    funding_id: funding_id(1),
                    amount: MicroUsd::new(100),
                },
                1 => RequestEvent::AttemptPrepared {
                    attempt_id: attempt,
                    kind: AttemptKind::Primary,
                    provider: fence.clone(),
                    lease_id: lease_id(1),
                    permit_id: permit_id(1),
                },
                2 => RequestEvent::AttemptReleased {
                    attempt_id: attempt_id(1),
                    reason: AttemptReleaseReason::PreAuthorizationFailure,
                },
                3 => RequestEvent::AttemptPrepared {
                    attempt_id: attempt_id(2),
                    kind: AttemptKind::Alternate,
                    provider: fence.clone(),
                    lease_id: lease_id(2),
                    permit_id: permit_id(2),
                },
                4 => RequestEvent::AttemptPrepared {
                    attempt_id: attempt_id(3),
                    kind: AttemptKind::Hedge,
                    provider: fence.clone(),
                    lease_id: lease_id(3),
                    permit_id: permit_id(3),
                },
                5 => RequestEvent::StartAuthorized {
                    attempt_id: attempt_id(1),
                    provider: fence.clone(),
                },
                6 => RequestEvent::StartAuthorized {
                    attempt_id: attempt_id(2),
                    provider: fence.clone(),
                },
                7 => RequestEvent::FirstContent {
                    attempt_id: attempt,
                    provider: fence.clone(),
                },
                8 => RequestEvent::Terminated {
                    disposition: TerminalDisposition::Released,
                },
                9 => RequestEvent::Terminated {
                    disposition: TerminalDisposition::Settled {
                        charged: MicroUsd::new(90),
                    },
                },
                10 => RequestEvent::DeadlineAsserted {
                    deadline: AbsoluteDeadline::new(1_001).expect("valid"),
                },
                11 => RequestEvent::AttemptPrepared {
                    attempt_id: attempt_id(9),
                    kind: AttemptKind::Hedge,
                    provider: fence.clone(),
                    lease_id: lease_id(1),
                    permit_id: permit_id(1),
                },
                _ => RequestEvent::Terminated {
                    disposition: TerminalDisposition::ReviewPending {
                        reason: ReviewReason::AccountingFailure,
                    },
                },
            };
            // Reusing a small event-ID domain deliberately generates replay
            // conflicts in addition to illegal lifecycle transitions.
            let event = RecordedRequestEvent {
                id: event_id((index % 11) as u128 + 10_000),
                digest: Digest::new([operation.wrapping_add(index as u8); 32]),
                payload,
            };
            let before = state.clone();
            match reduce(
                &state,
                &event,
                &context(
                    u64::try_from(index + 1).expect("small trace"),
                    std::slice::from_ref(&fence),
                ),
            ) {
                Ok(reduction) => {
                    if !state.is_terminal()
                        && reduction.state.is_terminal()
                        && reduction.outcome == ApplyOutcome::Applied
                    {
                        successful_terminals = successful_terminals
                            .checked_add(1)
                            .expect("at most one terminal");
                    }
                    state = reduction.state;
                }
                Err(_) => prop_assert_eq!(&state, &before),
            }

            prop_assert_eq!(state.deadline(), deadline);
            prop_assert!(state.validate_invariants().is_ok());
            prop_assert_eq!(
                state.resources().acquired_leases(),
                state.resources().acquired_permits()
            );
            prop_assert_eq!(
                state.resources().released_leases(),
                state.resources().released_permits()
            );
            prop_assert!(state.resources().released_leases()
                <= state.resources().acquired_leases());
            prop_assert!(successful_terminals <= 1);
            if state.is_terminal() {
                prop_assert!(state.terminal().is_some());
                prop_assert_eq!(state.resources().active_leases().expect("valid"), 0);
                prop_assert_eq!(state.resources().active_permits().expect("valid"), 0);
            }
        }
    }
}
