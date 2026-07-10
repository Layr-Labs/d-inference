//! Concurrent MemoryLedger.settle after resize up with withdrawable.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_up_wdr_then_concurrent_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 10_000_000).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // reserved_wdr=1M
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 3_000_000)
            .unwrap();
        // reserved=3M reserved_wdr=3M; bal=7M wdr=7M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Charge 2M of 3M all-wdr reserved → refund 1M wdr
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                2_000_000,
                "ru-d",
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
    // bal=7M+1M=8M; wdr=7M+1M=8M
    assert_eq!(bal, 8_000_000);
    assert_eq!(wdr, 8_000_000);
}
