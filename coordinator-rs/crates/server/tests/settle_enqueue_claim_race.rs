//! Concurrent MemoryLedger.outbox claim after settle enqueues.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::outbox::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_enqueue_then_claim_drains() {
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
            assert!(g
                .settle(
                    OperationKey(format!("s{i}")),
                    &jid,
                    "a",
                    50_000,
                    &format!("d{i}"),
                )
                .unwrap());
            box_
                .lock()
                .unwrap()
                .enqueue("inference.settled", &jid)
                .unwrap();
        }
    }
    assert_eq!(box_.lock().unwrap().len(), 4);

    let mut handles = Vec::new();
    for _ in 0..4 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.try_claim().map(|e| e.id)
        }));
    }

    let mut ids = std::collections::HashSet::new();
    for h in handles {
        if let Some(id) = h.join().unwrap() {
            assert!(ids.insert(id));
        }
    }
    assert_eq!(ids.len(), 4);
    assert!(box_.lock().unwrap().is_empty());
}
