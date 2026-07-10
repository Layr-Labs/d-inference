//! Concurrent settle_capped vs release on reserved-only job: XOR.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_vs_release_on_reserved_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 160_000)
            .unwrap();
    }

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            90_000,
            45_000,
            "d-sc-rel",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel:j".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let capped_ok = capped.join().unwrap();
    let released = release.join().unwrap();
    assert!(capped_ok ^ released, "exactly one must win");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if capped_ok {
        // charged min(90k, 45k, 160k) = 45k → refund 115k → bal = 5M - 160k + 115k = 4.955M
        assert_eq!(g.balance("a").0, 4_955_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    } else {
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
