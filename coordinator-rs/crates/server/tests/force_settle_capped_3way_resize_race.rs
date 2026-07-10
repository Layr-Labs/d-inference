//! Concurrent force_settle vs settle vs settle_capped after resize: exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_settle_capped_after_resize_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 600_000)
            .unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 130_000, "force-3way-rz")
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
            130_000,
            "settle-3way-rz",
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
            400_000,
            130_000,
            "capped-3way-rz",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    let wins = (forced as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1, "exactly one clear path");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // charged 130k of 600k → refund 470k → bal = 5M - 600k + 470k = 4.87M
    assert_eq!(g.balance("a").0, 4_870_000);
    let disp = g.job_disposition("j").unwrap();
    if forced {
        assert_eq!(disp, "force_settled");
    } else {
        assert_eq!(disp, "settled");
    }
}
