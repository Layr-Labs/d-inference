//! Concurrent release with same op key but different job: Conflict after first.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_same_op_different_job_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r0".into()), "j0", "a", 100_000)
            .unwrap();
        g.reserve(OperationKey("r1".into()), "j1", "a", 100_000)
            .unwrap();
        assert!(g
            .release(OperationKey("rel-shared".into()), "j0", "a")
            .unwrap());
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.release(OperationKey("rel-shared".into()), "j1", "a") {
                Ok(true) => panic!("mismatched job must not release"),
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
    // j0 released; j1 still reserved
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 9_900_000);
}
