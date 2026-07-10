//! Resize down then concurrent settle within shrunk reservation.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_down_then_concurrent_settle_within_new_reservation() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 250_000)
            .unwrap();
        assert_eq!(g.job_reserved_total("j").unwrap().0, 250_000);
        assert_eq!(g.balance("a").0, 4_750_000);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // 200k is within 250k resized reservation.
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
    // reserved 250k, charged 200k → refund 50k → bal = 4.75M + 50k = 4.8M
    assert_eq!(g.balance("a").0, 4_800_000);
}
