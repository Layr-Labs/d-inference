//! Concurrent settle vs release on the same job: exactly one money move.
//! Release after start_authorized is forbidden, so if mark already happened
//! before this race, only settle can win.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_and_release_exactly_one_disposition() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .map(|applied| applied)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let settled = settle.join().unwrap();
    let released = release.join().unwrap();
    // Job is already start_authorized, so release must always fail.
    assert!(!released, "release must not succeed after start_authorized");
    assert!(settled, "settle must succeed");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 9_600_000);
}

#[test]
fn concurrent_settle_and_release_before_start_auth() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // Not start-authorized yet.
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        // Settle without start_authorized still works if disposition unset —
        // but our settle path doesn't require funded_start. Release may win first.
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .map(|applied| applied)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let settled = settle.join().unwrap();
    let released = release.join().unwrap();
    assert!(
        settled ^ released,
        "exactly one disposition; settled={settled} released={released}"
    );
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
