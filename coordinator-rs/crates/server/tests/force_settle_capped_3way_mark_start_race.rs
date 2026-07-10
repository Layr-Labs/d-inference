//! Concurrent force_settle vs settle vs settle_capped after mark_start: exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_settle_capped_after_mark_start_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 500_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 110_000, "force-3way")
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
            110_000,
            "settle-3way",
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
            110_000,
            "capped-3way",
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
    // charged 110k of 500k → refund 390k → bal = 5M - 500k + 390k = 4.89M
    assert_eq!(g.balance("a").0, 4_890_000);
    let disp = g.job_disposition("j").unwrap();
    if forced {
        assert_eq!(disp, "force_settled");
    } else {
        assert_eq!(disp, "settled");
    }
}
