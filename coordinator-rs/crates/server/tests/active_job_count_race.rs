//! Concurrent MemoryLedger.active_job_count under parallel reserve/release.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_active_job_count_tracks_reserve_release() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock()
        .unwrap()
        .credit("a", 20_000_000, 0)
        .unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 500_000)
                .unwrap();
            let mid = g.active_job_count();
            g.release(OperationKey(format!("rel{i}")), &jid, "a")
                .unwrap();
            mid
        }));
    }

    let mids: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    // Each mid count is between 1 and 8 depending on interleaving
    for m in &mids {
        assert!(*m >= 1 && *m <= 8, "mid={m}");
    }
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
    assert_eq!(led.lock().unwrap().balance("a").0, 20_000_000);
}
