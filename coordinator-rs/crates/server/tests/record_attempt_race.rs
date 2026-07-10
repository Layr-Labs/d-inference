//! Concurrent MemoryLedger.record_attempt under parallel settles.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_record_attempt_then_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.record_attempt(&format!("att-{i}"), "j", "prov", "started");
            g.attempt(&format!("att-{i}")).is_some()
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }

    {
        let mut g = led.lock().unwrap();
        assert!(g.settle(OperationKey("s".into()), "j", "a", 100_000, "d").unwrap());
        // Attempts remain lookupable after settle
        for i in 0..4 {
            assert!(g.attempt(&format!("att-{i}")).is_some());
            assert_eq!(g.attempt(&format!("att-{i}")).unwrap().job_id, "j");
        }
    }
}
