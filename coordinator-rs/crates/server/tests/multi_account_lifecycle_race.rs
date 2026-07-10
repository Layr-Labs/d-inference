//! Concurrent MemoryLedger.ownership-style: multiple accounts independent.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_lifecycle_independent_accounts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("alice", 5_000_000, 0).unwrap();
        g.credit("bob", 5_000_000, 0).unwrap();
    }

    let led_a = led.clone();
    let alice = thread::spawn(move || {
        let mut g = led_a.lock().unwrap();
        g.reserve(OperationKey("ra".into()), "ja", "alice", 1_000_000)
            .unwrap();
        g.mark_start_authorized("ja").unwrap();
        g.settle(OperationKey("sa".into()), "ja", "alice", 200_000, "da")
            .unwrap()
    });
    let led_b = led.clone();
    let bob = thread::spawn(move || {
        let mut g = led_b.lock().unwrap();
        g.reserve(OperationKey("rb".into()), "jb", "bob", 1_000_000)
            .unwrap();
        g.mark_start_authorized("jb").unwrap();
        g.settle(OperationKey("sb".into()), "jb", "bob", 300_000, "db")
            .unwrap()
    });

    assert!(alice.join().unwrap());
    assert!(bob.join().unwrap());
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("alice").0, 4_800_000);
    assert_eq!(g.balance("bob").0, 4_700_000);
}
