//! Concurrent force_settle_held vs settle_capped: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_and_settle_capped_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 400_000, "force-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_s = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle_capped(
            OperationKey("sc".into()),
            "j",
            "a",
            800_000,
            400_000,
            "cap-d",
        )
        .map(|a| a)
        .unwrap_or(false)
    });

    let forced = force.join().unwrap();
    let settled = capped.join().unwrap();
    assert!(
        forced ^ settled,
        "exactly one; forced={forced} settled={settled}"
    );
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Both charge 400k → bal 9.6M either way
    assert_eq!(g.balance("a").0, 9_600_000);
}
