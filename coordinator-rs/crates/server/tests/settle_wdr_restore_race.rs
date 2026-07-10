//! Concurrent reserve then settle with withdrawable provenance restore.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_settle_restores_unused_withdrawable() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    // Start with mix of non-wdr and wdr.
    led.lock()
        .unwrap()
        .credit("a", 10_000_000, 4_000_000)
        .unwrap();

    // Single reserve then concurrent settle — settle race already covered;
    // here we assert provenance restore after a single settle under contention
    // with a parallel no-op settle attempt.
    {
        let mut g = led.lock().unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 1_000_000, "td1")
            .unwrap()
    });
    let led_n = led.clone();
    let noop = thread::spawn(move || {
        let mut g = led_n.lock().unwrap();
        g.settle(OperationKey("s2".into()), "j", "a", 1_000_000, "td1")
            .map(|a| a)
            .unwrap_or(false)
    });

    assert!(settle.join().unwrap());
    assert!(!noop.join().unwrap());
    let (bal, wdr) = led.lock().unwrap().balance("a");
    // After reserve: bal=5M. Charge 1M of 5M reserved.
    // non_wdr available before reserve was 6M; reserved consumed non_wdr first.
    // Start: bal=10M wdr=4M → non_wdr=6M.
    // Reserve 5M: consumes 5M non_wdr, 0 wdr → bal=5M wdr=4M, reserved_wdr=0.
    // Settle charge 1M: refund 4M all non_wdr → bal=9M wdr=4M.
    assert_eq!(bal, 9_000_000);
    assert_eq!(wdr, 4_000_000);
}
