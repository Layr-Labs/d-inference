//! Fenced settle/release refuse wrong epoch under concurrency (DECISIONS #56).

use darkbloom_coordinator::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_fenced_settle_wrong_epoch_all_ownership_lost() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 11)
            .unwrap();
        g.mark_start_authorized_fenced(11, "j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            matches!(
                g.settle_capped_fenced(
                    99,
                    OperationKey(format!("s{i}")),
                    "j",
                    "a",
                    10,
                    10,
                    &format!("d{i}"),
                ),
                Err(LedgerError::OwnershipLost)
            )
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }

    let g = led.lock().unwrap();
    assert_eq!(g.held_start_authorized_count(), 1);
    assert_eq!(g.balance("a").0, 4_900_000);
}

#[test]
fn concurrent_fenced_release_wrong_epoch_all_ownership_lost() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 4)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            matches!(
                g.release_fenced(7, OperationKey(format!("rel{i}")), "j", "a"),
                Err(LedgerError::OwnershipLost)
            )
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 4_900_000);
}
