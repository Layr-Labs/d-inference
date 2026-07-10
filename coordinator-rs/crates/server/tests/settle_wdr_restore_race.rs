//! Concurrent settle with withdrawable provenance restore.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_restores_unused_withdrawable() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    // Start: bal=10M wdr=4M → non_wdr=6M
    led.lock()
        .unwrap()
        .credit("a", 10_000_000, 4_000_000)
        .unwrap();
    {
        let mut g = led.lock().unwrap();
        // Reserve 5M: consumes 5M non_wdr → reserved_wdr=0
        g.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        // After reserve: bal=5M wdr=4M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Charge 1M of 5M reserved (all non_wdr reserved) → refund 4M non_wdr
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                1_000_000,
                "td-wdr",
            )
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
    // Charge 1M, refund 4M → bal=9M; wdr unchanged at 4M
    assert_eq!(bal, 9_000_000);
    assert_eq!(wdr, 4_000_000);
}
