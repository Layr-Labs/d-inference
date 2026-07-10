//! Concurrent settle_capped same op key with different actual: Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_same_op_different_actual_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g
            .settle_capped(
                OperationKey("sc-shared".into()),
                "j",
                "a",
                500_000,
                100_000,
                "d-sc-shared",
            )
            .unwrap());
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle_capped(
                OperationKey("sc-shared".into()),
                "j",
                "a",
                600_000 + i as i64,
                100_000,
                "d-sc-other",
            ) {
                Ok(true) => panic!("mismatched actual must not settle_capped"),
                Ok(false) => false,
                Err(LedgerError::Conflict(_)) => true,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
    let g = led.lock().unwrap();
    // Charged min(500k, 100k, 1M) = 100k → bal = 4.9M
    assert_eq!(g.balance("a").0, 4_900_000);
    assert_eq!(g.active_job_count(), 0);
}
