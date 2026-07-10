//! Concurrent force_settle vs settle_capped after resize: XOR clear.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_settle_capped_after_resize_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 350_000)
            .unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 90_000, "force-rz-sc")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            200_000,
            90_000,
            "capped-rz-sc",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(forced ^ capped_ok, "exactly one clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Both charge 90k of 350k → refund 260k → bal = 5M - 350k + 260k = 4.91M
    assert_eq!(g.balance("a").0, 4_910_000);
    if forced {
        assert_eq!(g.job_disposition("j"), Some("force_settled"));
    } else {
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
