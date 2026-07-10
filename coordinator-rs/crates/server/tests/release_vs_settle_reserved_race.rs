//! Concurrent release vs settle on reserved (not authorized): XOR.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_vs_settle_on_reserved_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 180_000)
            .unwrap();
        // Not start_authorized — both release and settle are allowed.
    }

    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel:j".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            60_000,
            "d-rsv-xor",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let released = release.join().unwrap();
    let settled = settle.join().unwrap();
    assert!(released ^ settled, "exactly one must win");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if released {
        assert_eq!(g.balance("a").0, 5_000_000);
    } else {
        // charged 60k of 180k → refund 120k → bal = 5M - 180k + 120k = 4.94M
        assert_eq!(g.balance("a").0, 4_940_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
