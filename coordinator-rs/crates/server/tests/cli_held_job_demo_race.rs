//! Concurrent MemoryLedger.CLI held-job demo path under race.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cli_style_held_job_demo() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("pilot-account", 1_000_000, 0).unwrap();
        g.reserve(
            OperationKey("reserve:held".into()),
            "held-job",
            "pilot-account",
            100_000,
        )
        .unwrap();
        g.mark_start_authorized("held-job").unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "held-job").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::HeldForReview);
    }
    assert_eq!(led.lock().unwrap().balance("pilot-account").0, 900_000);
    assert_eq!(led.lock().unwrap().held_start_authorized_count(), 1);
}
