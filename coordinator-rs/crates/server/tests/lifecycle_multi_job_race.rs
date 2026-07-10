//! Concurrent MemoryLedger.credit then reserve then settle full lifecycle under race.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_full_lifecycle_distinct_jobs() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock()
        .unwrap()
        .credit("a", 20_000_000, 0)
        .unwrap();

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 1_000_000)
                .unwrap();
            g.mark_start_authorized(&jid, "a").unwrap();
            g.settle(
                OperationKey(format!("s{i}")),
                &jid,
                "a",
                250_000,
                &format!("d{i}"),
            )
            .unwrap()
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // 20M - 4*1M + 4*(1M-250k) = 20M - 4M + 3M = 19M
    assert_eq!(g.balance("a").0, 19_000_000);
}
