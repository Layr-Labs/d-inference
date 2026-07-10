//! Concurrent reserve of the same job_id: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_same_job_id_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
    }
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.reserve(
                OperationKey(format!("r-{i}")),
                "shared-job",
                "a",
                100_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1, "exactly one reserve must apply for a shared job_id");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    // 10M - 100k
    assert_eq!(g.balance("a").0, 9_900_000);
}
