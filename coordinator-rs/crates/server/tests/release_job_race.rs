//! Concurrent release of the same job under distinct op keys: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_same_job_distinct_ops_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 2_000_000).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
    }
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.release(OperationKey(format!("rel-{i}")), "j", "a")
                .map(|applied| applied)
                .unwrap_or(false)
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1, "disposition gate allows only one release");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a"), (10_000_000, 2_000_000));
}
