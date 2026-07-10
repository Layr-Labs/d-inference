//! Concurrent MemoryLedger.job_funded_start / held count under parallel mark.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_distinct_jobs_all_fund() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        for i in 0..4 {
            g.reserve(
                OperationKey(format!("r{i}")),
                &format!("j{i}"),
                "a",
                500_000,
            )
            .unwrap();
        }
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.mark_start_authorized(&format!("j{i}")).is_ok()
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 4);
    let g = led.lock().unwrap();
    assert_eq!(g.held_start_authorized_count(), 4);
    assert_eq!(g.active_job_count(), 4);
    let mut ids = g.held_start_authorized_job_ids();
    ids.sort();
    assert_eq!(ids, vec!["j0", "j1", "j2", "j3"]);
}
