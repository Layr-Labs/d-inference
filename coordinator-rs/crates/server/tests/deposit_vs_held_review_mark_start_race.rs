//! Concurrent held-review while deposit after mark_start: deposit applies, review HeldForReview.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_held_review_after_mark_start() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 400_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 120_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_held_ms", "a", 55_000, 10_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        reviews.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    let deposited = deposit.join().unwrap();
    assert!(deposited);
    for h in reviews {
        assert_eq!(h.join().unwrap(), RecoveryAction::HeldForReview);
    }

    let g = led.lock().unwrap();
    assert_eq!(g.held_start_authorized_count(), 1);
    assert_eq!(g.active_job_count(), 1);
    // Seed 400k + deposit 55k - reserved 120k = 335k free
    assert_eq!(g.balance("a").0, 335_000);
}
