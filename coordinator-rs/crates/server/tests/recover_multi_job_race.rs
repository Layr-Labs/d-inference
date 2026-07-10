//! Concurrent recover_undispatched across distinct reserved jobs.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_distinct_reserved_jobs_all_release() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        for i in 0..4 {
            g.reserve(
                OperationKey(format!("r{i}")),
                &format!("j{i}"),
                "a",
                500_000,
            )
            .unwrap();
        }
        assert_eq!(g.active_job_count(), 4);
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched(&led, &format!("j{i}"), "a").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::Released);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 10_000_000);
}
