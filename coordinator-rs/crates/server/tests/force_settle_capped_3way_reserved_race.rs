//! Concurrent 3-way force/settle/settle_capped on reserved-only: exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_settle_capped_on_reserved_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 280_000)
            .unwrap();
        // Not start_authorized — force_settle_held requires start_authorized,
        // so force should Skip/AlreadyTerminal-ish; settle and capped race.
        // Actually force_settle_held on reserved-only returns Skipped.
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 70_000, "force-rsv-3way")
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
            70_000,
            "settle-rsv-3way",
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
            70_000,
            "capped-rsv-3way",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    // force must not win on reserved-only (not start_authorized)
    assert!(!forced, "force_settle requires start_authorized");
    assert!(settled ^ capped_ok, "exactly one of settle/capped");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // charged 70k of 280k → refund 210k → bal = 5M - 280k + 210k = 4.93M
    assert_eq!(g.balance("a").0, 4_930_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
