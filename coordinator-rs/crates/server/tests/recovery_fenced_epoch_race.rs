//! Fenced recovery refuses wrong epoch under concurrency (DECISIONS #59).

use darkbloom_coordinator::{
    force_settle_held_fenced, recover_undispatched_fenced, MemoryLedger, OperationKey,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_held_fenced_wrong_epoch_all_err() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 12)
            .unwrap();
        g.mark_start_authorized_fenced(12, "j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held_fenced(&led, 99, "j", "a", 10, &format!("d{i}")).is_err()
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(led.lock().unwrap().held_start_authorized_count(), 1);
    assert_eq!(led.lock().unwrap().balance("a").0, 4_900_000);
}

#[test]
fn concurrent_recover_undispatched_fenced_wrong_epoch_all_err() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 5)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched_fenced(&led, 1, "j", "a").is_err()
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(led.lock().unwrap().active_job_count(), 1);
}
