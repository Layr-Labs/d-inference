//! Concurrent settle vs settle_capped after resize: XOR clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_vs_settle_capped_after_resize_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 450_000)
            .unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            120_000,
            "d-settle-rz",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            300_000,
            120_000,
            "d-capped-rz",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(settled ^ capped_ok, "exactly one clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Both charge 120k of 450k → refund 330k → bal = 5M - 450k + 330k = 4.88M
    assert_eq!(g.balance("a").0, 4_880_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
