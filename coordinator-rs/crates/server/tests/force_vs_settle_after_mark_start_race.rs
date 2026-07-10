//! Concurrent force_settle vs settle after mark_start: XOR clear with matching disposition.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_settle_after_mark_start_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 400_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 100_000, "force-ms-xor")
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
            100_000,
            "settle-ms-xor",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    assert!(forced ^ settled, "exactly one money clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    let disp = g.job_disposition("j").unwrap();
    if forced {
        assert_eq!(disp, "force_settled");
    } else {
        assert_eq!(disp, "settled");
    }
    // reserved 400k, charged 100k → refund 300k → bal = 5M - 400k + 300k = 4.9M
    assert_eq!(g.balance("a").0, 4_900_000);
}
