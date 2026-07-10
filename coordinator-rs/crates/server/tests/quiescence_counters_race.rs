//! Concurrent MemoryLedger.quiescence-relevant counters under parallel lifecycle.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_lifecycle_quiescence_counters_end_zero() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock()
        .unwrap()
        .credit("a", 20_000_000, 0)
        .unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 500_000)
                .unwrap();
            g.mark_start_authorized(&jid, "a").unwrap();
            g.settle(
                OperationKey(format!("s{i}")),
                &jid,
                "a",
                100_000,
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
    assert_eq!(g.held_start_authorized_count(), 0);
    assert!(g.held_start_authorized_job_ids().is_empty());
    // 20M - 8*500k + 8*(500k-100k) = 20M - 4M + 3.2M = 19.2M
    assert_eq!(g.balance("a").0, 19_200_000);
}
