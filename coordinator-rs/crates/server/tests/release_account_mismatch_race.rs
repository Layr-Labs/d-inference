//! Concurrent release with wrong account: all Conflict; correct account releases.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_wrong_account_never_moves_money() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.release(OperationKey(format!("rel-wrong:{i}")), "j", "b") {
                Ok(true) => panic!("wrong account must not release"),
                Ok(false) => false,
                Err(LedgerError::Conflict(_)) => true,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }

    {
        let mut g = led.lock().unwrap();
        assert_eq!(g.balance("a").0, 4_000_000);
        assert_eq!(g.balance("b").0, 5_000_000);
        assert!(g.release(OperationKey("rel-ok".into()), "j", "a").unwrap());
        assert_eq!(g.balance("a").0, 5_000_000);
        assert_eq!(g.balance("b").0, 5_000_000);
        assert_eq!(g.active_job_count(), 0);
    }
}
