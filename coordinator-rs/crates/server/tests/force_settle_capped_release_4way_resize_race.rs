//! Concurrent 4-way clear after resize (force included; release fails): exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_4way_clear_after_resize_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 450_000)
            .unwrap();
    }

    let led_rel = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_rel.lock().unwrap();
        match g.release(OperationKey("rel:j".into()), "j", "a") {
            Ok(true) => panic!("release must not succeed after start_authorized"),
            Ok(false) => false,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 95_000, "force-4way-rz")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            95_000,
            "settle-4way-rz",
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
            250_000,
            95_000,
            "capped-4way-rz",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let released = release.join().unwrap();
    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(!released);
    let wins = (forced as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1);

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // charged 95k of 450k → refund 355k → bal = 5M - 450k + 355k = 4.905M
    assert_eq!(g.balance("a").0, 4_905_000);
    if forced {
        assert_eq!(g.job_disposition("j"), Some("force_settled"));
    } else {
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
