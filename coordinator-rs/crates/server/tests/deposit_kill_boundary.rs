//! Kill-boundary: observe succeeds, then credit fails → forget restores event id.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;

/// Simulate a poisoned credit path by using a custom wrapper that observes
/// then fails — verifying forget compensation via public API.
#[test]
fn forget_allows_retry_after_manual_observe_without_credit() {
    let mut inbox = ExternalEventInbox::new();
    let mut led = MemoryLedger::default();
    // Manually observe without crediting (crash between observe and credit).
    assert!(inbox.observe("stripe", "evt_crash").unwrap());
    assert_eq!(led.balance("a").0, 0);
    // Replay would be a no-op if we don't forget — poison.
    assert!(!inbox.observe("stripe", "evt_crash").unwrap());
    // Compensate (as apply_stripe_deposit does on credit Err).
    assert!(inbox.forget("stripe", "evt_crash"));
    // Retry succeeds and credits.
    assert!(apply_stripe_deposit(
        &mut inbox,
        &mut led,
        "stripe",
        "evt_crash",
        "a",
        1_000_000,
        500_000
    )
    .unwrap());
    assert_eq!(led.balance("a"), (1_000_000, 500_000));
}
