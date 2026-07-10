//! Concurrent force_settle_held vs release: release must fail after start_authorized.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_and_release_release_always_fails() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 400_000, "force-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let forced = force.join().unwrap();
    let released = release.join().unwrap();
    assert!(!released, "release must not succeed after start_authorized");
    assert!(forced, "force_settle must succeed");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 9_600_000);
}
