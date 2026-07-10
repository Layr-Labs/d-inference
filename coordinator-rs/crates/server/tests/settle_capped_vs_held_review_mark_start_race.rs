//! Concurrent settle_capped while held-review after mark_start.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_vs_held_review_after_mark_start() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 260_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            150_000,
            55_000,
            "capped-held-ms",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        reviews.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    let capped_ok = capped.join().unwrap();
    assert!(capped_ok);
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
    // charged 55k of 260k → refund 205k → bal = 5M - 260k + 205k = 4.945M
    assert_eq!(g.balance("a").0, 4_945_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
