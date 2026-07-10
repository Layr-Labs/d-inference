//! Concurrent settle exceeding resized-down reservation: all Conflict until clamp path.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_over_resized_reservation_all_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 100_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // 500k exceeds resized reservation of 100k → Conflict (raw settle).
            match g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                500_000,
                &format!("d-{i}"),
            ) {
                Ok(true) => panic!("must not settle above reservation"),
                Ok(false) => false,
                Err(LedgerError::Conflict(_)) => true,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    let mut conflicts = 0usize;
    for h in handles {
        if h.join().unwrap() {
            conflicts += 1;
        }
    }
    assert_eq!(conflicts, 8);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.job_reserved_total("j").unwrap().0, 100_000);
    assert_eq!(g.balance("a").0, 4_900_000);
}
