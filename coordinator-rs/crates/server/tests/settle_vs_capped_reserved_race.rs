//! Concurrent settle vs settle_capped on reserved-only job: XOR.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_vs_settle_capped_on_reserved_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 240_000)
            .unwrap();
        // Not start_authorized — both settle paths allowed.
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            80_000,
            "d-rsv-s",
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
            150_000,
            80_000,
            "d-rsv-c",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(settled ^ capped_ok, "exactly one clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Both charge 80k of 240k → refund 160k → bal = 5M - 240k + 160k = 4.92M
    assert_eq!(g.balance("a").0, 4_920_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
