//! Concurrent MemoryLedger.resize up consuming withdrawable.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_up_consumes_withdrawable() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // bal=5M wdr=5M (all withdrawable)
        g.credit("a", 5_000_000, 5_000_000).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // reserved_wdr=1M; bal=4M wdr=4M
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Upsize to 2M → need +1M from remaining all-wdr
            g.resize_and_authorize(
                OperationKey(format!("ra-{i}")),
                "j",
                "a",
                2_000_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.job_reserved_total("j").unwrap().0, 2_000_000);
    // reserved_wdr should be 2M (1M original + 1M added)
    // bal=4M-1M=3M; wdr=4M-1M=3M
    assert_eq!(g.balance("a"), (3_000_000, 3_000_000));
}
