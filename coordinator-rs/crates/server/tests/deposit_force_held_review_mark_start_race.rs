//! Concurrent deposit while force_settle vs held-review after mark_start.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_force_vs_held_review_after_mark_start() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 720_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 180_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_fh_ms", "a", 88_000, 22_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 48_000, "force-dep-held-ms")
            .map(|a| a == RecoveryAction::Released)
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
    let forced = force.join().unwrap();
    assert!(deposited);
    assert!(forced);
    for h in reviews {
        match h.join().unwrap() {
            RecoveryAction::HeldForReview | RecoveryAction::AlreadyTerminal => {}
            other => panic!("unexpected {other:?}"),
        }
    }

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    // Seed 720k + deposit 88k = 808k. Charged 48k → free = 760k
    assert_eq!(g.balance("a").0, 760_000);
}
