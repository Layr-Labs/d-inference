//! Unit tests for every cancellation-ladder rung (plan sections 13.1-13.6).

mod common;

use common::*;
use darkbloom_core::money::Tokens;
use darkbloom_core::request::{Effect, Event, Phase, RequestOutcome, ReviewReason};

fn is_release_job(e: &Effect) -> bool {
    matches!(e, Effect::ReleaseJob)
}

fn is_complete(e: &Effect) -> bool {
    matches!(e, Effect::CompleteRequest { .. })
}

/// 13.1 — cancel before any provider write while admitting: release the
/// financial job, no cancel frame, no provider effects.
#[test]
fn rung_13_1_cancel_before_write_while_admitting() {
    let mut d = Driver::new();
    d.ok(Event::ReserveCommitted);
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, is_release_job));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::Cancelled
        }
    )));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::SendCancel { .. }
    ) || matches!(
        e,
        Effect::AbortLease { .. }
    )));
    d.ok(Event::ReleaseRecorded);
    assert!(d.machine.is_finished());
}

/// 13.1 — cancel with a queued, unwritten prepare frame: discard the frame,
/// release the permit and the job. No cancel frame is needed.
#[test]
fn rung_13_1_cancel_discards_queued_frame() {
    let mut d = Driver::new();
    d.ok(Event::ReserveCommitted);
    d.ok(Event::AdmitGranted {
        attempt: attempt(1),
        provider: provider(1),
    });
    // Write never confirmed: the frame is still queued.
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::DiscardQueuedFrame { attempt: a } if *a == attempt(1)
    )));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::ReleasePermit { attempt: a } if *a == attempt(1)
    )));
    assert!(has_effect(&effects, is_release_job));
}

/// 13.2 — write outcome unknown: no release, no retry. Money moves only
/// after provider evidence arrives.
#[test]
fn rung_13_2_sent_unknown_awaits_evidence() {
    let mut d = Driver::new();
    d.ok(Event::ReserveCommitted);
    d.ok(Event::AdmitGranted {
        attempt: attempt(1),
        provider: provider(1),
    });
    d.ok(Event::PrepareWriteUnknown {
        attempt: attempt(1),
    });
    let effects = d.ok(Event::ConsumerCancelled);
    // The consumer is answered, but nothing is released or retried.
    assert!(has_effect(&effects, is_complete));
    assert!(!has_effect(&effects, is_release_job));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::RequestAdmission { .. }
    )));

    // Evidence: the provider never got it (session loss). Now release.
    let effects = d.ok(Event::SessionLost {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, is_release_job));
    d.ok(Event::ReleaseRecorded);
    assert!(d.machine.is_finished());
}

/// 13.2 — evidence can also be a late prepared lease: it is aborted, and
/// release follows the abort acknowledgement.
#[test]
fn rung_13_2_late_prepared_lease_aborts_then_releases() {
    let mut d = Driver::new();
    d.ok(Event::ReserveCommitted);
    d.ok(Event::AdmitGranted {
        attempt: attempt(1),
        provider: provider(1),
    });
    d.ok(Event::PrepareWriteUnknown {
        attempt: attempt(1),
    });
    d.ok(Event::ConsumerCancelled);
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(100),
        hedge_offer: None,
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::AbortLease { attempt: a, lease: l } if *a == attempt(1) && *l == lease(1)
    )));
    assert!(
        !has_effect(&effects, is_release_job),
        "release waits for abort ack (13.3)"
    );
    let effects = d.ok(Event::AbortAcked {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, is_release_job));
}

/// 13.3 — prepared but not started: idempotent abort; release only after
/// abort acknowledgement.
#[test]
fn rung_13_3_prepared_not_started_aborts() {
    let mut d = Driver::new();
    d.ok(Event::ReserveCommitted);
    d.ok(Event::AdmitGranted {
        attempt: attempt(1),
        provider: provider(1),
    });
    d.ok(Event::PrepareWriteConfirmed {
        attempt: attempt(1),
    });
    // Unusable facts with no hedge and no... actually usable facts, but the
    // consumer cancels before funding fires: simulate cancel first.
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(
        !has_effect(&effects, is_release_job),
        "frame on wire: await evidence"
    );
    let effects = d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(100),
        hedge_offer: None,
    });
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::AbortLease { .. }
    )));
    // No funding may fire under cancellation.
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::FundAndAuthorize { .. }
    )));
    let effects = d.ok(Event::AbortAcked {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, is_release_job));
    d.ok(Event::ReleaseRecorded);
    assert!(d.machine.is_finished());
}

/// 13.3 — prepared-lease expiry is an alternative release path.
#[test]
fn rung_13_3_lease_expiry_releases() {
    let mut d = Driver::new();
    d.drive_to_preparing();
    d.ok(Event::ConsumerCancelled);
    d.ok(Event::PreparedArrived {
        attempt: attempt(1),
        lease: lease(1),
        facts: facts(100),
        hedge_offer: None,
    });
    let effects = d.ok(Event::AttemptTimedOut {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, is_release_job));
}

/// 13.4 — started before content: idempotent cancel, lease retained, no
/// alternate. Cancel acknowledgement (durable quiescence) releases in full.
#[test]
fn rung_13_4_started_before_content_cancels_no_alternate() {
    let mut d = Driver::new();
    d.drive_to_awaiting_content();
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SendCancel { attempt: a, .. } if *a == attempt(1)
    )));
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::RequestAdmission { .. })),
        "no alternate after start authorization (9.2.4)"
    );
    assert!(
        !has_effect(&effects, is_release_job),
        "money held until quiescence evidence"
    );
    assert!(matches!(d.machine.phase(), Phase::AwaitingTerminal { .. }));

    let effects = d.ok(Event::CancelAcked {
        attempt: attempt(1),
    });
    assert!(has_effect(&effects, is_release_job));
    d.ok(Event::ReleaseRecorded);
    assert!(d.machine.is_finished());
}

/// 13.4 — cancel during the start round trip uses abort (tombstone if start
/// lost, cancellation-with-terminal if start won, plan 10.3).
#[test]
fn rung_13_4_cancel_during_starting_uses_abort() {
    let mut d = Driver::new();
    d.drive_to_starting();
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::AbortLease { .. }
    )));
    let effects = d.ok(Event::AbortAcked {
        attempt: attempt(1),
    });
    assert!(
        has_effect(&effects, is_release_job),
        "tombstone beat start: full release"
    );
}

/// 13.4 — session loss for a started attempt does NOT release money; the
/// reservation is held for terminal replay via review.
#[test]
fn rung_13_4_session_loss_after_start_holds_money() {
    let mut d = Driver::new();
    d.drive_to_awaiting_content();
    let effects = d.ok(Event::SessionLost {
        attempt: attempt(1),
    });
    assert!(!has_effect(&effects, is_release_job));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::EscalateReview {
            reason: ReviewReason::ProviderLostAfterStart
        }
    )));
}

/// 13.5 — after first content: never reroute; cancel and await the bounded
/// terminal window; settle authenticated partial usage when the terminal
/// arrives.
#[test]
fn rung_13_5_after_content_cancel_then_partial_settlement() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    d.ok(Event::ContentAccepted {
        attempt: attempt(1),
        cumulative_tokens: Tokens::new(42),
    });
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SendCancel { .. }
    )));
    assert!(!has_effect(&effects, |e| matches!(
        e,
        Effect::RequestAdmission { .. }
    )));

    // Terminal with partial usage arrives inside the bounded window.
    let effects = d.ok(Event::TerminalArrived {
        attempt: attempt(1),
        terminal: terminal(7, darkbloom_core::request::TerminalOutcome::Cancelled, 60),
    });
    let settle = filter_effects(&effects, |e| matches!(e, Effect::SettleJob { .. }));
    assert_eq!(settle.len(), 1);
    if let Effect::SettleJob {
        accepted_checkpoint,
        ..
    } = settle[0]
    {
        assert_eq!(
            accepted_checkpoint.get(),
            42,
            "settlement is capped at the accepted-chunk checkpoint (13.6)"
        );
    }
    d.ok(Event::SettlementRecorded);
    assert!(d.machine.is_finished());
}

/// 13.5 — bounded terminal window elapses without a terminal: escalate to
/// review; the reservation stays held (10.6: never infer delivery).
#[test]
fn rung_13_5_terminal_window_elapses_to_review() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    d.ok(Event::ConsumerCancelled);
    let effects = d.ok(Event::TerminalWaitElapsed);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::EscalateReview {
            reason: ReviewReason::TerminalTimeoutAfterContent
        }
    )));
    assert!(!has_effect(&effects, is_release_job));
}

/// 13.6 — consumer pipe stall cancels provider work with its own outcome.
#[test]
fn rung_13_6_pipe_stall_cancels() {
    let mut d = Driver::new();
    d.drive_to_streaming();
    let effects = d.ok(Event::ConsumerPipeStalled);
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::SendCancel { .. }
    )));
    assert!(has_effect(&effects, |e| matches!(
        e,
        Effect::CompleteRequest {
            outcome: RequestOutcome::ConsumerBackpressure
        }
    )));
}

/// Cancel during `Reserving`: the reservation may still commit; it is
/// released the moment it does, and nothing is dispatched.
#[test]
fn cancel_during_reserving_releases_on_commit() {
    let mut d = Driver::new();
    let effects = d.ok(Event::ConsumerCancelled);
    assert!(has_effect(&effects, is_complete));
    let effects = d.ok(Event::ReserveCommitted);
    assert!(has_effect(&effects, is_release_job));
    assert!(
        !has_effect(&effects, |e| matches!(e, Effect::RequestAdmission { .. })),
        "no admission after cancel"
    );
    d.ok(Event::ReleaseRecorded);
    assert!(d.machine.is_finished());
}
