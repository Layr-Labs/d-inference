//! Concurrent force_settle vs held-review after resize: force clears, review never moves money.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_held_review_after_resize() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 400_000)
            .unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 150_000, "force-resize-d")
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

    let forced = force.join().unwrap();
    let mut held = 0usize;
    let mut terminal = 0usize;
    for h in reviews {
        match h.join().unwrap() {
            RecoveryAction::HeldForReview => held += 1,
            RecoveryAction::AlreadyTerminal => terminal += 1,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(forced);
    assert_eq!(held + terminal, 8);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    // reserved 400k, charged 150k → refund 250k → bal = 5M - 400k + 250k = 4.85M
    assert_eq!(g.balance("a").0, 4_850_000);
}
