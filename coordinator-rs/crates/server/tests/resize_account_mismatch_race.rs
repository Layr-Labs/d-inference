//! Concurrent MemoryLedger.resize_and_authorize account mismatch: Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_account_mismatch_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Wrong account for the job
            matches!(
                g.resize_and_authorize(
                    OperationKey(format!("ra-{i}")),
                    "j",
                    "b",
                    1_000_000,
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
    let g = led.lock().unwrap();
    assert!(!g.job_funded_start("j"));
    assert_eq!(g.balance("a").0, 4_000_000);
    assert_eq!(g.balance("b").0, 5_000_000);
}
