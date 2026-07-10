//! Concurrent settle while held-review after resize_and_authorize.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_vs_held_review_after_resize_auth() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 280_000)
            .unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            90_000,
            "settle-held-rz",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        reviews.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    let settled = settle.join().unwrap();
    assert!(settled);
    let mut held = 0usize;
    let mut terminal = 0usize;
    for h in reviews {
        match h.join().unwrap() {
            RecoveryAction::HeldForReview => held += 1,
            RecoveryAction::AlreadyTerminal => terminal += 1,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(held + terminal, 8);

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // charged 90k of 280k → refund 190k → bal = 5M - 280k + 190k = 4.91M
    assert_eq!(g.balance("a").0, 4_910_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
