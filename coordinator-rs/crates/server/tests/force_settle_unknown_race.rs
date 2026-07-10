//! Concurrent force_settle_held on unknown job: Skipped or AlreadyTerminal.

use darkbloom_coordinator::ledger::MemoryLedger;
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_unknown_job_skipped() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "missing", "a", 100, &format!("d-{i}")).unwrap()
        }));
    }

    for h in handles {
        let action = h.join().unwrap();
        assert!(
            matches!(
                action,
                RecoveryAction::Skipped | RecoveryAction::AlreadyTerminal
            ),
            "got {action:?}"
        );
    }
}
