//! Concurrent mark_start vs recover_undispatched: XOR release or authorize.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_vs_recover_undispatched_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 150_000)
            .unwrap();
    }

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j").is_ok()
    });

    let led_r = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_r, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let marked = mark.join().unwrap();
    let released = recover.join().unwrap();
    assert!(
        marked ^ released,
        "exactly one of mark_start or recover-release must win"
    );

    let g = led.lock().unwrap();
    if marked {
        assert!(g.job_funded_start("j"));
        assert_eq!(g.active_job_count(), 1);
        assert_eq!(g.balance("a").0, 4_850_000);
        // recover must have Skipped
        assert!(!released);
    } else {
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 5_000_000);
        assert!(!g.job_funded_start("j"));
    }
}
