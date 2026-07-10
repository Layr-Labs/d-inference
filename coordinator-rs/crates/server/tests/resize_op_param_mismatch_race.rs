//! Concurrent resize_and_authorize same op key with different amount: Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_same_op_different_amount_conflicts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        assert!(g
            .resize_and_authorize(OperationKey("ra".into()), "j", "a", 200_000)
            .unwrap()
            .applied);
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Same op key, different target amount — must Conflict, not silent noop.
            match g.resize_and_authorize(
                OperationKey("ra".into()),
                "j",
                "a",
                300_000 + i as i64,
            ) {
                Ok(r) if r.applied => panic!("mismatched amount must not resize"),
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
    assert!(g.job_funded_start("j"));
    // 10M - 100k reserve - 100k upsize = 9.8M
    assert_eq!(g.balance("a").0, 9_800_000);
    assert_eq!(g.job_reserved_total("j").map(|m| m.0), Some(200_000));
}
