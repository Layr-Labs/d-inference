//! Concurrent settle vs held-review after mark_start: settle clears, review never moves money.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_vs_held_review_after_mark_start() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 300_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            120_000,
            "settle-ms-d",
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
    // reserved 300k, charged 120k → refund 180k → bal = 5M - 300k + 180k = 4.88M
    assert_eq!(g.balance("a").0, 4_880_000);
}
