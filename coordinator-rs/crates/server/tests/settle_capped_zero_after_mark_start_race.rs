//! Concurrent settle_capped zero after mark_start: full refund.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_zero_after_mark_start_full_refund() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 275_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert_eq!(g.balance("a").0, 4_725_000);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle_capped(
                OperationKey(format!("sc-{i}")),
                "j",
                "a",
                100_000,
                0,
                "d-zms",
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }

    let mut wins = 0usize;
    for h in handles {
        if h.join().unwrap() {
            wins += 1;
        }
    }
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 5_000_000);
}
