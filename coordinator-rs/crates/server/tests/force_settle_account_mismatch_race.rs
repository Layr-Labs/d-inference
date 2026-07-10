//! Concurrent force_settle with wrong account: all Conflict; correct clears hold.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_wrong_account_never_clears() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            match force_settle_held(&led, "j", "b", 100_000, &format!("d-{i}")) {
                Ok(RecoveryAction::Released) => panic!("wrong account must not force_settle"),
                Ok(_) => false,
                Err(_) => true, // Conflict from account mismatch
            }
        }));
    }
    let mut errs = 0usize;
    for h in handles {
        if h.join().unwrap() {
            errs += 1;
        }
    }
    assert_eq!(errs, 8);
    {
        let g = led.lock().unwrap();
        assert_eq!(g.balance("a").0, 4_000_000);
        assert_eq!(g.balance("b").0, 5_000_000);
        assert_eq!(g.active_job_count(), 1);
    }
    assert_eq!(
        force_settle_held(&led, "j", "a", 100_000, "d-ok").unwrap(),
        RecoveryAction::Released
    );
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a").0, 4_900_000);
    assert_eq!(g.balance("b").0, 5_000_000);
    assert_eq!(g.active_job_count(), 0);
}
