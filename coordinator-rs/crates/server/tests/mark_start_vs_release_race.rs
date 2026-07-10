//! Concurrent mark_start_authorized vs release: mutually exclusive outcomes.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_and_release_mutually_exclusive() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j").is_ok()
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected release error: {e}"),
        }
    });

    let marked = mark.join().unwrap();
    let released = release.join().unwrap();
    assert!(
        marked ^ released,
        "exactly one of mark_start/release must apply; marked={marked} released={released}"
    );

    let g = led.lock().unwrap();
    if marked {
        assert!(g.job_funded_start("j"));
        assert_eq!(g.active_job_count(), 1);
        assert_eq!(g.balance("a").0, 9_000_000);
    } else {
        assert!(!g.job_funded_start("j"));
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 10_000_000);
    }
}

#[test]
fn release_after_start_authorized_conflicts() {
    let mut led = MemoryLedger::default();
    led.credit("a", 5_000_000, 0).unwrap();
    led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
        .unwrap();
    led.mark_start_authorized("j").unwrap();
    assert!(matches!(
        led.release(OperationKey("rel".into()), "j", "a"),
        Err(LedgerError::Conflict(_))
    ));
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.balance("a").0, 4_000_000);
}
