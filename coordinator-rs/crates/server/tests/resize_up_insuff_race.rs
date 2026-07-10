//! Concurrent resize_and_authorize upsize insufficient: at most one succeeds.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_up_insufficient_at_most_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // After reserve 1M, remaining bal = 500k — only one upsize to +400k fits.
        g.credit("a", 1_500_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.resize_and_authorize(
                OperationKey(format!("ra-{i}")),
                "j",
                "a",
                1_400_000,
            ) {
                Ok(r) => r.applied,
                Err(LedgerError::InsufficientBalance) | Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected {e}"),
            }
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
    assert_eq!(g.job_reserved_total("j").unwrap().0, 1_400_000);
    // 1.5M - 1M - 0.4M = 100k
    assert_eq!(g.balance("a").0, 100_000);
}
