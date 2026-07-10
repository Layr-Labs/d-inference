//! Concurrent force_settle: winner records force_settled disposition.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_records_force_settled_disposition() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "j", "a", 250_000, &format!("d-{i}"))
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
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    assert_eq!(g.active_job_count(), 0);
    // reserved 1M, charged 250k → refund 750k → bal = 5M - 1M + 750k = 4.75M
    assert_eq!(g.balance("a").0, 4_750_000);
}
