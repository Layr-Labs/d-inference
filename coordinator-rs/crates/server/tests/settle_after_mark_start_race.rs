//! Concurrent settle after mark_start (no resize): charge within original reservation.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_after_mark_start_within_reservation() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 500_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                200_000,
                &format!("d-{i}"),
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
    assert_eq!(g.active_job_count(), 0);
    // reserved 500k, charged 200k → refund 300k → bal = 5M - 500k + 300k = 4.8M
    assert_eq!(g.balance("a").0, 4_800_000);
}
