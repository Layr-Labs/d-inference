//! Concurrent release vs mark_start: XOR release or authorize.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_vs_mark_start_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 120_000)
            .unwrap();
    }

    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        match g.release(OperationKey("rel".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j", "a").is_ok()
    });

    let released = release.join().unwrap();
    let marked = mark.join().unwrap();
    assert!(
        released ^ marked,
        "exactly one of release or mark_start must win"
    );

    let g = led.lock().unwrap();
    if released {
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 5_000_000);
        assert!(!g.job_funded_start("j"));
    } else {
        assert_eq!(g.active_job_count(), 1);
        assert!(g.job_funded_start("j"));
        assert_eq!(g.balance("a").0, 4_880_000);
    }
}
