//! Unit tests for the request lifecycle: happy path, hedging (plan 11.8),
//! funding race, terminal idempotency/conflict (plan 10.6), ambiguous start
//! (plan 9.2.11), and deadline behavior (plan 9.2.5).

mod common;

use common::*;
use darkbloom_core::money::Tokens;
use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_core::request::{
    Effect, Event, HedgeOffer, Phase, RequestOutcome, TerminalOutcome, TransitionError,
};

#[test]
fn happy_path_settles_at_checkpoint() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    d.ok(Event::ContentAccepted {
        attempt: attempt(1),
        cumulative_tokens: Tokens::new(120),
    });
    let effects = d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: terminal(1, TerminalOutcome::Completed, 120),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SettleJob { accepted_checkpoint, .. } if accepted_checkpoint.get() == 120
    )));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::Completed
        }
    )));
    d.ok(Event::SettlementRecorded);
    assert!(d.machine.is_finished());
}

#[test]
fn preamble_does_not_commit() {
    let mut d = Driver::new();
    d.drive_to_awaiting_content();
    d.ok(Event::PreambleAccepted {
        attempt: attempt(1),
    });
    assert!(
        d.machine.committed_attempt().is_none(),
        "9.2.7: preamble never commits"
    );
    assert!(matches!(d.machine.phase(), Phase::AwaitingContent { .. }));
    d.ok(Event::ContentAccepted {
        attempt: attempt(1),
        cumulative_tokens: Tokens::new(1),
    });
    assert_eq!(d.machine.committed_attempt(), Some(attempt(1)));
    assert!(matches!(d.machine.phase(), Phase::Streaming { .. }));
}

#[test]
fn hedge_timer_dispatches_one_hedge_and_first_usable_lease_wins() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    // Primary prepare is slow: the caller-armed hedge timer fires with a
    // pre-authorized offer.
    d.advance(1_000);
    let effects = d.ok(Event::HedgeTimerFired {
        offer: Some(HedgeOffer {
            attempt: attempt(2),
            provider: provider(2),
        }),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SendPrepare { attempt: a, provider: p } if *a == attempt(2) && *p == provider(2)
    )));

    // The hedge prepares first with usable facts: it wins funding.
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(2),
        lease: lease(2),
        facts: facts(300),
        hedge_offer: None,
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::FundAndAuthorize { attempt: a, .. } if *a == attempt(2)
    )));

    // The primary prepares late: it lost the race and is aborted (13.3).
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(300),
        hedge_offer: None,
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::AbortLease { attempt: a, lease: l } if *a == attempt(1) && *l == lease(1)
    )));
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::FundAndAuthorize { .. })),
        "the funding CAS fires at most once (9.2.3)"
    );
}

#[test]
fn second_hedge_timer_fire_is_a_noop_and_returns_offer() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    d.ok(Event::HedgeTimerFired {
        offer: Some(HedgeOffer {
            attempt: attempt(2),
            provider: provider(2),
        }),
    });
    // A second offer must be returned: at most one hedge ever (9.2.4).
    let effects = d.ok(Event::HedgeTimerFired {
        offer: Some(HedgeOffer {
            attempt: attempt(3),
            provider: provider(3),
        }),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::ReturnHedgeOffer { attempt: a, .. } if *a == attempt(3)
    )));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::SendPrepare { .. }
    )));
}

#[test]
fn unusable_facts_trigger_hedge_from_prepared_event() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    d.advance(9_800);
    // 500ms ETA against a 200ms remaining budget: facts fail (11.8).
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(500),
        hedge_offer: Some(HedgeOffer {
            attempt: attempt(2),
            provider: provider(2),
        }),
    });
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::FundAndAuthorize { .. })),
        "unusable lease is not funded while a hedge is possible"
    );
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SendPrepare { attempt: a, .. } if *a == attempt(2)
    )));
}

#[test]
fn unusable_facts_with_unused_offer_returns_it() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    // Usable facts: the offer must be returned, not consumed.
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(200),
        hedge_offer: Some(HedgeOffer {
            attempt: attempt(2),
            provider: provider(2),
        }),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::FundAndAuthorize { attempt: a, .. } if *a == attempt(1)
    )));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::ReturnHedgeOffer { attempt: a, .. } if *a == attempt(2)
    )));
}

#[test]
fn ambiguous_start_resends_same_identity_never_alternate() {
    let mut d = Driver::new();
    d.drive_to_starting();
    d.ok(Event::StartWriteUnknown {
        attempt: attempt(1),
    });
    let effects = d.ok(Event::StartRetryTimerFired);
    let sends = filter_effects(&effects, |e| matches!(e, Effect::SendStart { .. }));
    assert_eq!(sends.len(), 1, "9.2.11: resend the same idempotent start");
    if let Effect::SendStart {
        attempt: a,
        lease: l,
    } = sends[0]
    {
        assert_eq!(*a, attempt(1));
        assert_eq!(*l, lease(1));
    }
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::RequestAdmission { .. }
    )));
}

#[test]
fn duplicate_terminal_same_digest_is_idempotent() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    let t = terminal(9, TerminalOutcome::Completed, 50);
    d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: t,
    });
    let effects = d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: t,
    });
    assert!(
        effects.is_empty(),
        "12.8: same digest returns prior disposition, no effects"
    );
}

#[test]
fn conflicting_terminal_digest_moves_no_money() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: terminal(9, TerminalOutcome::Completed, 50),
    });
    let effects = d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: terminal(10, TerminalOutcome::Completed, 999),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::RecordTerminalConflict { .. }
    )));
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::SettleJob { .. })),
        "10.6: a conflicting terminal cannot move money"
    );
}

#[test]
fn zero_output_terminal_before_content_releases_in_full() {
    let mut d = Driver::new();
    d.drive_to_awaiting_content();
    let effects = d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: terminal(3, TerminalOutcome::Error(ProviderErrorClass::Fault), 0),
    });
    assert!(has_effect(&effects, |e| matches!(e, Effect::ReleaseJob)));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::SettleJob { .. }
    )));
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::RequestAdmission { .. })),
        "11.8: no alternate after start authorization, even after a zero-output terminal"
    );
}

#[test]
fn sequential_alternate_after_retryable_rejection() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    let effects = d.ok(Event::PrepareRejected {
        attempt: attempt(1),
        class: ProviderErrorClass::Capacity,
    });
    let admissions = filter_effects(&effects, |e| matches!(e, Effect::RequestAdmission { .. }));
    assert_eq!(admissions.len(), 1);
    if let Effect::RequestAdmission { exclude } = admissions[0] {
        assert!(
            exclude.contains(&provider(1)),
            "the alternate must exclude the attempted provider (11.1)"
        );
    }

    // Second rejection: the single alternate is spent — the request fails.
    d.ok(Event::AdmitGranted {
        attempt: attempt(2),
        provider: provider(2),
    });
    let effects = d.ok(Event::PrepareRejected {
        attempt: attempt(2),
        class: ProviderErrorClass::Capacity,
    });
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::RequestAdmission { .. }
    )));
    assert!(has_effect(&effects, |e| matches!(e, Effect::ReleaseJob)));
}

#[test]
fn invalid_request_rejection_never_retries() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    let effects = d.ok(Event::PrepareRejected {
        attempt: attempt(1),
        class: ProviderErrorClass::InvalidRequest,
    });
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::RequestAdmission { .. })),
        "10.5: invalid_request returns once, no retry"
    );
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::ProviderRejected {
                class: ProviderErrorClass::InvalidRequest
            }
        }
    )));
}

#[test]
fn deadline_event_before_deadline_is_rejected() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    assert!(matches!(
        d.err(Event::FirstContentDeadlineElapsed),
        TransitionError::DeadlineNotElapsed
    ));
}

#[test]
fn first_content_deadline_shared_across_attempts_never_resets() {
    let mut d = Driver::new();
    let initial = d.machine.deadlines();
    d.drive_to_preparing();
    // Alternate dispatch must not refresh the deadline (9.2.5).
    d.ok(Event::PrepareRejected {
        attempt: attempt(1),
        class: ProviderErrorClass::Draining,
    });
    d.ok(Event::AdmitGranted {
        attempt: attempt(2),
        provider: provider(2),
    });
    assert_eq!(d.machine.deadlines(), initial);

    // Deadline passes: the whole request fails even though the alternate is
    // younger than the primary was.
    d.now = darkbloom_core::time::TimestampMs::new(FIRST_CONTENT_DEADLINE);
    let effects = d.ok(Event::FirstContentDeadlineElapsed);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::DeadlineExceeded
        }
    )));
}

#[test]
fn content_before_start_authorization_is_a_protocol_violation() {
    let mut d = Driver::new();
    d.drive_to_funding();
    // Funding chosen but not authorized: emission is illegal (22.3).
    assert!(matches!(
        d.err(Event::ContentAccepted {
            attempt: attempt(1),
            cumulative_tokens: Tokens::new(1),
        }),
        TransitionError::PhaseMismatch { .. }
    ));
}

#[test]
fn fund_failure_aborts_lease_and_releases() {
    let mut d = Driver::new();
    d.drive_to_funding();
    let effects = d.ok(Event::FundFailed {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::AbortLease { .. }
    )));
    assert!(has_effect(&effects, |e| matches!(e, Effect::ReleaseJob)));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::FundingFailed
        }
    )));
    // The funding CAS is consumed: even a fresh usable lease cannot fund.
    assert_eq!(d.machine.funded_attempt(), Some(attempt(1)));
}

#[test]
fn lease_expiry_before_start_releases_job() {
    let mut d = Driver::new();
    d.drive_to_starting();
    let effects = d.ok(Event::AttemptTimedOut {
        attempt: attempt(1),
    });
    assert!(
        has_effect(&effects, |e| matches!(e, Effect::ReleaseJob)),
        "plan 18: explicit no-start/expiry releases the job"
    );
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::RequestAdmission { .. }
    )));
}

#[test]
fn session_loss_after_content_escalates_review() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    let effects = d.ok(Event::SessionLost {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::EscalateReview {
            reason: darkbloom_core::request::ReviewReason::ProviderLostAfterContent
        }
    )));
    assert!(!has_effect(&effects, |e| matches!(e, Effect::ReleaseJob)));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::SettleJob { .. }
    )));
}
