//! Concurrent MemoryLedger.resize_and_authorize then release attempt Conflict.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_authorize_then_release_conflict() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_a = led.clone();
    let authorize = thread::spawn(move || {
        let mut g = led_a.lock().unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 1_000_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(true) => "released",
            Ok(false) => "noop",
            Err(LedgerError::Conflict(_)) => "conflict",
            Err(e) => panic!("unexpected {e}"),
        }
    });

    let authorized = authorize.join().unwrap();
    let released = release.join().unwrap();
    // If authorize wins: released is conflict. If release wins: authorized false, released "released".
    assert!(
        (authorized && released == "conflict")
            || (!authorized && released == "released"),
        "authorized={authorized} released={released}"
    );
    let g = led.lock().unwrap();
    if authorized {
        assert!(g.job_funded_start("j"));
        assert_eq!(g.balance("a").0, 4_000_000);
    } else {
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
