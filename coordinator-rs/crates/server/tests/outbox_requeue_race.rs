//! Concurrent outbox try_claim then requeue: attempts preserved, no duplicates.

use darkbloom_coordinator::outbox::Outbox;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_claim_requeue_preserves_attempts_no_dup_ids() {
    let box_ = Arc::new(Mutex::new(Outbox::new(100)));
    {
        let mut g = box_.lock().unwrap();
        for i in 0..16 {
            g.enqueue("k", &format!("{i}")).unwrap();
        }
    }

    // Claim all, requeue half.
    let mut claimed = Vec::new();
    {
        let mut g = box_.lock().unwrap();
        while let Some(e) = g.try_claim() {
            claimed.push(e);
        }
    }
    assert_eq!(claimed.len(), 16);
    assert_eq!(box_.lock().unwrap().in_flight_len(), 16);
    assert_eq!(box_.lock().unwrap().len(), 16);

    let mut handles = Vec::new();
    for e in claimed.into_iter().take(8) {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.requeue(e).unwrap();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }

    let mut ids = HashSet::new();
    let mut attempts_ok = true;
    {
        let mut g = box_.lock().unwrap();
        while let Some(e) = g.try_claim() {
            assert!(ids.insert(e.id));
            if e.attempts < 2 {
                attempts_ok = false;
            }
        }
    }
    assert_eq!(ids.len(), 8);
    assert!(attempts_ok, "requeued entries must have attempts >= 2 after re-claim");
}
