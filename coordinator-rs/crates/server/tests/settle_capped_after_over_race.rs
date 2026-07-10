//! After settle-over-reservation conflicts, settle_capped still clears the hold.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn settle_capped_clears_hold_after_over_reservation_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 100_000)
            .unwrap();
        // Raw settle above reservation conflicts and must not poison.
        assert!(matches!(
            g.settle(OperationKey("s-bad".into()), "j", "a", 500_000, "d-bad"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(g.active_job_count(), 1);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle_capped(
                OperationKey(format!("sc-{i}")),
                "j",
                "a",
                500_000,
                500_000,
                "d-ok",
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }

    let mut wins = 0usize;
    for h in handles {
        if h.join().unwrap() {
            wins += 1;
        }
    }
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Charged min(500k, 500k, 100k) = 100k → bal stays 4.9M
    assert_eq!(g.balance("a").0, 4_900_000);
}
