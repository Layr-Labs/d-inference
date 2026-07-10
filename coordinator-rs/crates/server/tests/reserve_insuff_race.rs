//! Concurrent MemoryLedger.reserve insufficient: no partial debit under race.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_insufficient_at_most_one_succeeds() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 1_000_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.reserve(
                OperationKey(format!("r-{i}")),
                &format!("j-{i}"),
                "a",
                600_000,
            ) {
                Ok(r) => r.applied,
                Err(LedgerError::InsufficientBalance) => false,
                Err(e) => panic!("unexpected {e}"),
            }
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    // 1M balance, each wants 600k → at most one succeeds
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 400_000);
}
