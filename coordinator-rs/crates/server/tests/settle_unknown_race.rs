//! Concurrent MemoryLedger.settle unknown job: all Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_unknown_job_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 5_000_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            matches!(
                g.settle(
                    OperationKey(format!("s-{i}")),
                    "missing",
                    "a",
                    100,
                    &format!("d-{i}"),
                ),
                Err(LedgerError::Conflict(_))
            )
        }));
    }

    let conflicts: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|c| *c)
        .count();
    assert_eq!(conflicts, 8);
    assert_eq!(led.lock().unwrap().balance("a").0, 5_000_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
