//! Concurrent MemoryLedger.credit withdrawable > total: all Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_credit_wdr_exceeds_total_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 1_000, 0).unwrap();

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            matches!(
                g.credit("a", 100, 200),
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
    assert_eq!(led.lock().unwrap().balance("a"), (1_000, 0));
}
