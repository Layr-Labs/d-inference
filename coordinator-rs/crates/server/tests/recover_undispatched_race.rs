//! Concurrent recover_undispatched on a reserved (not start_authorized) job.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_undispatched_exactly_one_releases() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched(&led, "j", "a").unwrap()
        }));
    }

    let mut released = 0usize;
    let mut already = 0usize;
    for h in handles {
        match h.join().unwrap() {
            RecoveryAction::Released => released += 1,
            RecoveryAction::AlreadyTerminal => already += 1,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(released, 1, "exactly one recovery release");
    assert_eq!(already, 7);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 5_000_000);
}
