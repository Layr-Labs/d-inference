//! Concurrent release in 3-way with settle/capped on reserved: exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_settle_capped_on_reserved_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 190_000)
            .unwrap();
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
            50_000,
            "settle-rel-3way",
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
            100_000,
            50_000,
            "capped-rel-3way",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let released = release.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    let wins = (released as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1, "exactly one clear path");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if released {
        assert_eq!(g.balance("a").0, 5_000_000);
    } else {
        // charged 50k of 190k → refund 140k → bal = 5M - 190k + 140k = 4.95M
        assert_eq!(g.balance("a").0, 4_950_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
