//! Concurrent MemoryLedger.mark_start_authorized unknown job: all Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_unknown_job_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            matches!(
                g.mark_start_authorized("missing"),
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
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
