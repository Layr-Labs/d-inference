//! Concurrent mark_start_authorized with wrong account: all Conflict; correct can authorize.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_wrong_account_never_authorizes() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.mark_start_authorized("j", "b") {
                Ok(()) => panic!("wrong account must not mark_start_authorized"),
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
        assert!(!g.job_funded_start("j"));
        assert_eq!(g.balance("a").0, 4_000_000);
        assert_eq!(g.balance("b").0, 5_000_000);
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g.job_funded_start("j"));
        assert_eq!(g.held_start_authorized_count(), 1);
    }
}
