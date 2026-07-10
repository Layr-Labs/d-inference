//! Concurrent force_settle after resize down: charge clamps to resized reservation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_down_then_concurrent_force_settle_clamps_to_new_reservation() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 200_000)
            .unwrap();
        assert_eq!(g.job_reserved_total("j").unwrap().0, 200_000);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            // Ops asks for 900k but reservation is only 200k after resize.
            force_settle_held(&led, "j", "a", 900_000, &format!("d-{i}"))
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
    // After resize to 200k: bal = 5M - 200k = 4.8M; force charge full 200k → bal stays 4.8M
    assert_eq!(g.balance("a").0, 4_800_000);
}
