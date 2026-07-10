//! Concurrent recover_undispatched with wrong account: never credits wrong balance.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::recover_undispatched;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_undispatched_wrong_account_errors() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched(&led, "j", "b").is_err()
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
    assert!(recover_undispatched(&led, "j", "a").is_ok());
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a").0, 5_000_000);
    assert_eq!(g.balance("b").0, 5_000_000);
    assert_eq!(g.active_job_count(), 0);
}
