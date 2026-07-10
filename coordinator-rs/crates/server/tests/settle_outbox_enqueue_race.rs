//! Concurrent MemoryLedger.outbox enqueue from settle path simulation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::outbox::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_then_outbox_enqueue() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    let box_ = Arc::new(Mutex::new(Outbox::new(100)));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        for i in 0..4 {
            let jid = format!("j{i}");
            g.reserve(OperationKey(format!("r{i}")), &jid, "a", 500_000)
                .unwrap();
            g.mark_start_authorized(&jid).unwrap();
        }
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let jid = format!("j{i}");
            {
                let mut g = led.lock().unwrap();
                assert!(g
                    .settle(
                        OperationKey(format!("s{i}")),
                        &jid,
                        "a",
                        100_000,
                        &format!("d{i}"),
                    )
                    .unwrap());
            }
            let mut b = box_.lock().unwrap();
            b.enqueue("inference.settled", &format!("{{\"job\":\"{jid}\"}}"))
                .unwrap()
        }));
    }

    let mut ids = std::collections::HashSet::new();
    for h in handles {
        assert!(ids.insert(h.join().unwrap()));
    }
    assert_eq!(ids.len(), 4);
    assert_eq!(box_.lock().unwrap().len(), 4);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
