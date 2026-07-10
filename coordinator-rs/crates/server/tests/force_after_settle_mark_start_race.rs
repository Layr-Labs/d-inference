//! Concurrent force_settle after dispose via settle: AlreadyTerminal.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_after_settle_already_terminal() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 200_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g
            .settle(OperationKey("s".into()), "j", "a", 70_000, "d-first")
            .unwrap());
        assert_eq!(g.active_job_count(), 0);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "j", "a", 50_000, &format!("late-{i}")).unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::AlreadyTerminal);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Original settle: charged 70k of 200k → bal = 5M - 200k + 130k = 4.93M
    assert_eq!(g.balance("a").0, 4_930_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
