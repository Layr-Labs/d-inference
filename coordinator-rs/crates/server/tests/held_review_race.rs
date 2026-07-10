//! Concurrent recover_start_authorized_held: classify-only, never moves money.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_held_review_never_moves_money() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::HeldForReview);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a").0, 4_000_000);
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.held_start_authorized_count(), 1);
}
