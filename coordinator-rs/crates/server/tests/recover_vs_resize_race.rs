//! Concurrent recover_undispatched vs resize_and_authorize: exactly one wins money path.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_vs_resize_authorize_exactly_one_terminal_or_auth() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        // Not yet start_authorized — both recover and resize can race.
    }

    let led_rec = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_rec, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let led_rz = led.clone();
    let resize = thread::spawn(move || {
        let mut g = led_rz.lock().unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 200_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });

    let released = recover.join().unwrap();
    let resized = resize.join().unwrap();
    assert!(
        released ^ resized,
        "exactly one of recover-release or resize-authorize must win"
    );

    let g = led.lock().unwrap();
    if released {
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 5_000_000);
        assert!(!g.job_funded_start("j"));
    } else {
        assert_eq!(g.active_job_count(), 1);
        assert!(g.job_funded_start("j"));
        assert_eq!(g.job_reserved_total("j").unwrap().0, 200_000);
        assert_eq!(g.balance("a").0, 4_800_000);
    }
}
