//! Concurrent release vs recover_undispatched: XOR release (same effect).

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_vs_recover_undispatched_exactly_one_release() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 90_000)
            .unwrap();
    }

    let led_rel = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_rel.lock().unwrap();
        match g.release(OperationKey("cancel_release:j".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_rec = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_rec, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let released_direct = release.join().unwrap();
    let released_recover = recover.join().unwrap();
    // Exactly one path applies the release; the other sees AlreadyTerminal/false.
    assert!(
        released_direct ^ released_recover,
        "exactly one release must apply"
    );

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 5_000_000);
}
