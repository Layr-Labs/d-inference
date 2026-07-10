//! Concurrent MemoryLedger.settle with withdrawable-only charge.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_exact_withdrawable_charge() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // bal=5M, wdr=5M
        g.credit("a", 5_000_000, 5_000_000).unwrap();
        // Reserve 3M → reserved_wdr=3M
        g.reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        // bal=2M wdr=2M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Charge exactly reserved_wdr (3M)
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                3_000_000,
                "full-wdr-d",
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
    // Charge full 3M reserved (all wdr) → no refund → bal=2M wdr=2M
    assert_eq!(bal, 2_000_000);
    assert_eq!(wdr, 2_000_000);
}
