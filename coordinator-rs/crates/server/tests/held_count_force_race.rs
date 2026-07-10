//! Concurrent MemoryLedger.held_start_authorized_count under mutations.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_held_count_tracks_force_settle_clear() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        for i in 0..4 {
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 500_000)
                .unwrap();
            g.mark_start_authorized(&jid, "a").unwrap();
        }
        assert_eq!(g.held_start_authorized_count(), 4);
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, &format!("j{i}"), "a", 100_000, &format!("d{i}"))
                .map(|a| a == RecoveryAction::Released)
                .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 4);
    let g = led.lock().unwrap();
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.active_job_count(), 0);
    // 10M - 4*500k + 4*(500k-100k) = 10M - 2M + 1.6M = 9.6M
    assert_eq!(g.balance("a").0, 9_600_000);
}
