//! Concurrent MemoryLedger.release unknown job: all Ok(false) noop.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_unknown_job_all_noop() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 5_000_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.release(OperationKey(format!("rel-{i}")), "missing", "a")
                .unwrap()
        }));
    }

    for h in handles {
        assert!(!h.join().unwrap());
    }
    assert_eq!(led.lock().unwrap().balance("a").0, 5_000_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
