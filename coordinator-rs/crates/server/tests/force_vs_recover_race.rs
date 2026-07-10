//! Concurrent force_settle_held vs recover_undispatched on a start_authorized job.
//! recover_undispatched must Skip (never release); force_settle clears the hold.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_undispatched, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_and_recover_undispatched_never_releases() {
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
    let led_r = led.clone();
    let recover = thread::spawn(move || recover_undispatched(&led_r, "j", "a").unwrap());

    let forced = force.join().unwrap();
    let recovered = recover.join().unwrap();
    assert!(
        forced,
        "force_settle must clear the start_authorized hold"
    );
    assert_ne!(
        recovered,
        RecoveryAction::Released,
        "recover_undispatched must never release a start_authorized job; got {recovered:?}"
    );
    assert!(
        matches!(
            recovered,
            RecoveryAction::Skipped | RecoveryAction::AlreadyTerminal
        ),
        "expected Skipped or AlreadyTerminal, got {recovered:?}"
    );
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.balance("a").0, 9_600_000);
}
