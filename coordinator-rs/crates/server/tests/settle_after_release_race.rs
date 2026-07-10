//! Concurrent MemoryLedger.settle after release: all no-op (Ok false).

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_after_release_all_noop() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.release(OperationKey("rel".into()), "j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Disposed job → Ok(false) or Conflict depending on path;
            // never Ok(true).
            match g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                400_000,
                &format!("d-{i}"),
            ) {
                Ok(true) => panic!("settle must not apply after release"),
                Ok(false) => true,
                Err(_) => true, // Conflict also acceptable
            }
        }));
    }

    let safe: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|s| *s)
        .count();
    assert_eq!(safe, 8);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 5_000_000);
}
