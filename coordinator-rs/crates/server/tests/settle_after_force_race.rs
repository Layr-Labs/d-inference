//! Concurrent MemoryLedger.settle after force_settle: AlreadyTerminal/noop.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_after_force_settle_noop() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }
    assert_eq!(
        force_settle_held(&led, "j", "a", 400_000, "force-first").unwrap(),
        RecoveryAction::Released
    );

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                100_000,
                &format!("late-{i}"),
            ) {
                Ok(true) => panic!("must not apply after force_settle"),
                Ok(false) => true,
                Err(_) => true,
            }
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(led.lock().unwrap().balance("a").0, 4_600_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
