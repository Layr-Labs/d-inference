//! Concurrent held-review after force_settle: all AlreadyTerminal.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_held_review_after_force_settle_all_already_terminal() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 200_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }
    assert_eq!(
        force_settle_held(&led, "j", "a", 50_000, "force-first").unwrap(),
        RecoveryAction::Released
    );

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::AlreadyTerminal);
    }
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
    // 5M − 50k charged (200k reserved, 150k refunded) = 4.95M
    assert_eq!(g.balance("a").0, 4_950_000);
}
