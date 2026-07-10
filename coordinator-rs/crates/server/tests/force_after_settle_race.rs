//! Concurrent MemoryLedger.force_settle after already settled: AlreadyTerminal.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_after_normal_settle_already_terminal() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "normal-d")
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "j", "a", 100_000, &format!("late-{i}")).unwrap()
        }));
    }

    for h in handles {
        let action = h.join().unwrap();
        assert!(
            matches!(
                action,
                RecoveryAction::AlreadyTerminal | RecoveryAction::Skipped
            ),
            "got {action:?}"
        );
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 4_600_000);
}
