//! Concurrent recover_undispatched vs mark_start_authorized: mutually exclusive.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_and_mark_start_mutually_exclusive() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_r = led.clone();
    let recover = thread::spawn(move || {
        match recover_undispatched(&led_r, "j", "a").unwrap() {
            RecoveryAction::Released => true,
            _ => false,
        }
    });
    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j").is_ok()
    });

    let released = recover.join().unwrap();
    let marked = mark.join().unwrap();
    // Exactly one of: release (not start_authorized) OR mark_start.
    // If mark wins first, recover returns Skipped (not Released).
    assert!(
        released ^ marked || (!released && !marked),
        "released={released} marked={marked}"
    );
    // Actually if mark wins, recover returns Skipped so released=false, marked=true.
    // If recover wins, released=true, marked=false (job disposed).
    // Both false shouldn't happen under the mutex serialization of recover+mark
    // unless recover returns AlreadyTerminal somehow — tighten:
    assert!(
        (released && !marked) || (!released && marked),
        "exactly one outcome; released={released} marked={marked}"
    );
    let g = led.lock().unwrap();
    if marked {
        assert!(g.job_funded_start("j"));
        assert_eq!(g.active_job_count(), 1);
        assert_eq!(g.balance("a").0, 4_000_000);
    } else {
        assert!(!g.job_funded_start("j"));
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
