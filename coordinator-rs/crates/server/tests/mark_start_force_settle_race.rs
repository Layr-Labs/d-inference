//! Concurrent MemoryLedger.mark_start then force_settle on same job.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_then_force_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j", "a").is_ok()
    });
    let led_f = led.clone();
    let force = thread::spawn(move || {
        // May run before mark → Skipped; after mark → Released
        force_settle_held(&led_f, "j", "a", 400_000, "mf-d").unwrap()
    });

    let marked = mark.join().unwrap();
    let forced = force.join().unwrap();
    assert!(marked, "mark_start must succeed on reserved job");
    // If force ran before mark: Skipped, job still held funded
    // If force ran after mark: Released
    match forced {
        RecoveryAction::Released => {
            assert_eq!(led.lock().unwrap().active_job_count(), 0);
            assert_eq!(led.lock().unwrap().balance("a").0, 4_600_000);
        }
        RecoveryAction::Skipped => {
            assert!(led.lock().unwrap().job_funded_start("j"));
            assert_eq!(led.lock().unwrap().balance("a").0, 4_000_000);
            // Clean up for invariant
            assert_eq!(
                force_settle_held(&led, "j", "a", 400_000, "mf-d2").unwrap(),
                RecoveryAction::Released
            );
        }
        other => panic!("unexpected {other:?}"),
    }
}
