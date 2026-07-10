//! Concurrent MemoryLedger.reserve then release then re-reserve different job.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_release_rereserve_different_jobs() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock()
        .unwrap()
        .credit("a", 10_000_000, 0)
        .unwrap();

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 1_000_000)
                .unwrap();
            assert!(g
                .release(OperationKey(format!("rel{i}")), &jid, "a")
                .unwrap());
            // New job id after release
            g.reserve(
                OperationKey(format!("r2-{i}")),
                &format!("j{i}-b"),
                "a",
                500_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 4);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 4);
    // 10M - 4*500k = 8M
    assert_eq!(g.balance("a").0, 8_000_000);
}
