//! Concurrent MemoryLedger.settle exact reservation: charge full amount.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_exact_reservation_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
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
                1_000_000,
                "exact-d",
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
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Charge full 1M → no refund → bal = 4M
    assert_eq!(g.balance("a").0, 4_000_000);
}
