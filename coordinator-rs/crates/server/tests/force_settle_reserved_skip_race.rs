//! Concurrent force_settle_held on reserved (not authorized): all Skipped.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_on_reserved_all_skipped() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // Not start_authorized
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "j", "a", 100_000, &format!("d-{i}")).unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::Skipped);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert!(!g.job_funded_start("j"));
    assert_eq!(g.balance("a").0, 4_000_000);
}
