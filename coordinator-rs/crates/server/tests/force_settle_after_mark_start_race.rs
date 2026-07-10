//! Concurrent force_settle after mark_start (no resize): clamps to original reservation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_after_mark_start_clamps() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 250_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "j", "a", 9_000_000, &format!("d-{i}"))
                .map(|a| a == RecoveryAction::Released)
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
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    // Charged full 250k → bal = 5M - 250k = 4.75M
    assert_eq!(g.balance("a").0, 4_750_000);
}
