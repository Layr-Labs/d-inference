//! Concurrent MemoryLedger.force_settle with settle_capped zero after authorize.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_settle_capped_zero() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 0, "fz")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_s = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle_capped(OperationKey("sc".into()), "j", "a", 100_000, 0, "cz")
            .map(|a| a)
            .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let settled = capped.join().unwrap();
    assert!(
        forced ^ settled,
        "exactly one zero-charge clear; forced={forced} settled={settled}"
    );
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Either path charges 0 → full refund → bal 5M
    assert_eq!(g.balance("a").0, 5_000_000);
}
