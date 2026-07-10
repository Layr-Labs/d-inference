//! Concurrent 4-way clear after mark_start (force included): exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_4way_clear_after_mark_start_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 320_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        // release must Conflict after start_authorized
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
        force_settle_held(&led_f, "j", "a", 80_000, "force-4way-ms")
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
            80_000,
            "settle-4way-ms",
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
            200_000,
            80_000,
            "capped-4way-ms",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let released = release.join().unwrap();
    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(!released, "release forbidden after start_authorized");
    let wins = (forced as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1, "exactly one money clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // charged 80k of 320k → refund 240k → bal = 5M - 320k + 240k = 4.92M
    assert_eq!(g.balance("a").0, 4_920_000);
    if forced {
        assert_eq!(g.job_disposition("j"), Some("force_settled"));
    } else {
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
