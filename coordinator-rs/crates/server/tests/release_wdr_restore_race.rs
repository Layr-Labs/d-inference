//! Concurrent release restores withdrawable provenance exactly.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_restores_withdrawable_exactly() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // bal=10M, wdr=3M → non_wdr=7M
        g.credit("a", 10_000_000, 3_000_000).unwrap();
        // Reserve 5M: consumes 5M non_wdr → reserved_wdr=0
        g.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        // After reserve: bal=5M, wdr=3M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.release(OperationKey(format!("rel-{i}")), "j", "a")
                .map(|a| a)
                .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    let (bal, wdr) = led.lock().unwrap().balance("a");
    // Full restore: bal=10M, wdr=3M
    assert_eq!(bal, 10_000_000);
    assert_eq!(wdr, 3_000_000);
}
