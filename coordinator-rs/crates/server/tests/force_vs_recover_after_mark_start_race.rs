//! Concurrent force_settle vs recover_undispatched after mark_start.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_undispatched, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_vs_recover_after_mark_start() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 200_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 50_000, "force-ms-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let mut recovers = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        recovers.push(thread::spawn(move || {
            recover_undispatched(&led, "j", "a").unwrap()
        }));
    }

    let forced = force.join().unwrap();
    assert!(forced);
    for h in recovers {
        assert_eq!(h.join().unwrap(), RecoveryAction::Skipped);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    // reserved 200k, charged 50k → refund 150k → bal = 5M - 200k + 150k = 4.95M
    assert_eq!(g.balance("a").0, 4_950_000);
}
