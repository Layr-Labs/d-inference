//! Concurrent settle that consumes reserved withdrawable when charge exceeds non-wdr.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_consumes_reserved_withdrawable() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // bal=5M, wdr=5M (all withdrawable)
        g.credit("a", 5_000_000, 5_000_000).unwrap();
        // Reserve 3M → reserved_wdr=3M, bal=2M wdr=2M
        g.reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Charge 2M of 3M reserved (all was wdr) → consume 2M wdr, refund 1M wdr
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                2_000_000,
                "wdr-d",
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
    // Start after reserve: bal=2M wdr=2M. Charge 2M, refund 1M wdr → bal=3M wdr=3M
    assert_eq!(bal, 3_000_000);
    assert_eq!(wdr, 3_000_000);
}
