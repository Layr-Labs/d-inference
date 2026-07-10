//! Concurrent settle with same op key but different digest: all Conflict after first.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_same_op_different_digest_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g
            .settle(OperationKey("s-shared".into()), "j", "a", 100_000, "d-first")
            .unwrap());
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle(
                OperationKey("s-shared".into()),
                "j",
                "a",
                100_000,
                &format!("d-other-{i}"),
            ) {
                Ok(true) => panic!("mismatched digest must not settle"),
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
    assert_eq!(g.balance("a").0, 4_900_000);
    assert_eq!(g.active_job_count(), 0);
}
