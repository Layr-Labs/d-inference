//! Concurrent mark_start after resize_and_authorize: already authorized path.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_after_resize_authorize_idempotent_or_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 200_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.mark_start_authorized("j") {
                Ok(()) => true, // idempotent if already authorized
                Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    let mut conflicts = 0usize;
    for h in handles {
        if !h.join().unwrap() {
            conflicts += 1;
        }
    }
    // Already start_authorized via resize → all Conflict (not idempotent Ok).
    assert_eq!(conflicts, 8);
    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 4_800_000);
}
