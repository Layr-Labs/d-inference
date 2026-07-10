//! Concurrent MemoryLedger.held_start_authorized_job_ids under parallel force.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_clears_held_job_ids() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        for i in 0..3 {
            let jid = format!("job-{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 1_000_000)
                .unwrap();
            g.mark_start_authorized(&jid, "a").unwrap();
        }
        let mut ids = g.held_start_authorized_job_ids();
        ids.sort();
        assert_eq!(ids, vec!["job-0", "job-1", "job-2"]);
    }

    let mut handles = Vec::new();
    for i in 0..3 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, &format!("job-{i}"), "a", 100_000, &format!("d{i}"))
                .map(|a| a == RecoveryAction::Released)
                .unwrap_or(false)
        }));
    }

    assert_eq!(
        handles
            .into_iter()
            .filter_map(|h| h.join().ok())
            .filter(|w| *w)
            .count(),
        3
    );
    let g = led.lock().unwrap();
    assert!(g.held_start_authorized_job_ids().is_empty());
    assert_eq!(g.held_start_authorized_count(), 0);
}
