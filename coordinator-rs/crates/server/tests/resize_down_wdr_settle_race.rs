//! Concurrent MemoryLedger.settle after resize down with withdrawable restore.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_down_with_wdr_then_concurrent_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // bal=10M wdr=4M → non_wdr=6M
        g.credit("a", 10_000_000, 4_000_000).unwrap();
        // Reserve 5M: consumes 5M non_wdr → reserved_wdr=0
        g.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        // Resize down to 2M: refund 3M non_wdr first
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_000_000)
            .unwrap();
        // After: reserved=2M reserved_wdr=0; bal=10M-5M+3M=8M; wdr=4M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                500_000,
                "rd-d",
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
    // Charge 500k of 2M non_wdr reserved → refund 1.5M non_wdr
    // bal=8M+1.5M=9.5M; wdr stays 4M
    assert_eq!(bal, 9_500_000);
    assert_eq!(wdr, 4_000_000);
}
