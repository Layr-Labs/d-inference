//! Concurrent resize_and_authorize vs recover_undispatched: mutually exclusive.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_authorize_vs_recover_mutually_exclusive() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_a = led.clone();
    let authorize = thread::spawn(move || {
        let mut g = led_a.lock().unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 1_200_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let recover = thread::spawn(move || {
        matches!(
            recover_undispatched(&led_r, "j", "a").unwrap(),
            RecoveryAction::Released
        )
    });

    let authorized = authorize.join().unwrap();
    let released = recover.join().unwrap();
    assert!(
        authorized ^ released,
        "exactly one; authorized={authorized} released={released}"
    );
    let g = led.lock().unwrap();
    if authorized {
        assert!(g.job_funded_start("j"));
        assert_eq!(g.job_reserved_total("j").unwrap().0, 1_200_000);
        assert_eq!(g.balance("a").0, 8_800_000);
    } else {
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 10_000_000);
    }
}
