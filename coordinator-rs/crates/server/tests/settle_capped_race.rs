//! Concurrent MemoryLedger.settle_capped: billable cap respected under race.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_exactly_one_applies() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // actual=800k, cap=300k → charge 300k
            g.settle_capped(
                OperationKey(format!("sc-{i}")),
                "j",
                "a",
                800_000,
                300_000,
                "cap-d",
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
    // reserved 1M, charged 300k → refund 700k → bal = 10M-1M+700k = 9.7M
    assert_eq!(g.balance("a").0, 9_700_000);
}
