//! Concurrent MemoryLedger.settle actual exceeds reservation: all Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_over_reservation_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                1_000_001,
                &format!("d-{i}"),
            ) {
                Err(LedgerError::Conflict(_)) => true,
                Ok(false) => false, // disposed by a concurrent valid settle — shouldn't happen
                Ok(true) => panic!("over-reservation must not apply"),
                Err(e) => panic!("unexpected {e}"),
            }
        }));
    }

    let conflicts: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|c| *c)
        .count();
    assert_eq!(conflicts, 8);
    let g = led.lock().unwrap();
    // Job still held — no settle applied
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 4_000_000);
}
