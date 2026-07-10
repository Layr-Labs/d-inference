//! Concurrent pre-start cancel_release: exactly one release restores balance.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_pre_start_cancel_release_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 250_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.release(
                OperationKey(format!("cancel_release:j:{i}")),
                "j",
                "a",
            ) {
                Ok(applied) => applied,
                Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected: {e}"),
            }
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
    assert_eq!(g.balance("a").0, 5_000_000);
    assert_eq!(g.active_job_count(), 0);
}
