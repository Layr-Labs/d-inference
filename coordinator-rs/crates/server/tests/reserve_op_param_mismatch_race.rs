//! Concurrent reserve with same op key but different job: Conflict after first.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_same_op_different_job_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        assert!(g
            .reserve(OperationKey("op-shared".into()), "j0", "a", 100_000)
            .unwrap()
            .applied);
    }

    let mut handles = Vec::new();
    for i in 1..9 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.reserve(
                OperationKey("op-shared".into()),
                &format!("j{i}"),
                "a",
                100_000,
            ) {
                Ok(r) if r.applied => panic!("mismatched job must not reserve"),
                Ok(_) => false,
                Err(LedgerError::Conflict(_)) => true,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 9_900_000);
}
