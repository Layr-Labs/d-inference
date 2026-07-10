//! Concurrent recover_start_authorized_held on unknown/missing job.

use darkbloom_coordinator::ledger::MemoryLedger;
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_held_review_unknown_job_already_terminal() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "missing").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::AlreadyTerminal);
    }
}
