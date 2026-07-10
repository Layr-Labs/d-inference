//! Concurrent force_settle vs settle_capped after mark_start: XOR clear.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_settle_capped_after_mark_start_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 300_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 80_000, "force-sc")
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
            80_000,
            "capped-sc",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(forced ^ capped_ok, "exactly one clear");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Both charge 80k of 300k → refund 220k → bal = 5M - 300k + 220k = 4.92M
    assert_eq!(g.balance("a").0, 4_920_000);
    if forced {
        assert_eq!(g.job_disposition("j"), Some("force_settled"));
    } else {
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
