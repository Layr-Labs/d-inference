//! Resize up then concurrent force_settle clamps to enlarged reservation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_up_then_concurrent_force_settle_clamps_to_new_reservation() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 800_000)
            .unwrap();
        assert_eq!(g.job_reserved_total("j").unwrap().0, 800_000);
        assert_eq!(g.balance("a").0, 4_200_000);
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
    // Charged full 800k reservation → bal stays 4.2M
    assert_eq!(g.balance("a").0, 4_200_000);
}
