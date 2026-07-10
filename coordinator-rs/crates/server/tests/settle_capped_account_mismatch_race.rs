//! Concurrent settle_capped with wrong account: all Conflict; correct can settle.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_wrong_account_never_moves_money() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle_capped(
                OperationKey(format!("sc-wrong:{i}")),
                "j",
                "b",
                500_000,
                100_000,
                &format!("d-sc-wrong-{i}"),
            ) {
                Ok(true) => panic!("wrong account must not settle_capped"),
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
        assert!(g
            .settle_capped(
                OperationKey("sc-ok".into()),
                "j",
                "a",
                500_000,
                100_000,
                "d-sc-ok",
            )
            .unwrap());
        // Charged min(500k, 100k, 1M) = 100k → free = 4.9M
        assert_eq!(g.balance("a").0, 4_900_000);
        assert_eq!(g.balance("b").0, 5_000_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
