//! Concurrent cancel_release vs force_settle after start_authorized.
//! Release always fails; force_settle clears the hold.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cancel_release_vs_force_settle_after_auth() {
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
        force_settle_held(&led_f, "j", "a", 250_000, "force-cancel-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let mut release_handles = Vec::new();
    for i in 0..8 {
        let led_r = led.clone();
        release_handles.push(thread::spawn(move || {
            let mut g = led_r.lock().unwrap();
            match g.release(
                OperationKey(format!("cancel_release:j:{i}")),
                "j",
                "a",
            ) {
                Ok(applied) => applied,
                Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    let forced = force.join().unwrap();
    let mut released = 0usize;
    for h in release_handles {
        if h.join().unwrap() {
            released += 1;
        }
    }
    assert_eq!(released, 0);
    assert!(forced);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // reserved 1M, charged 250k → refund 750k → 9.75M
    assert_eq!(g.balance("a").0, 9_750_000);
}
