//! Outbox requeue after claim restores retryable pending work.

use darkbloom_coordinator::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn requeue_after_claim_restores_retryable_pending() {
    let box_ = Arc::new(Mutex::new(Outbox::new(16)));
    box_
        .lock()
        .unwrap()
        .enqueue("billing.deposit_applied", r#"{"e":1}"#)
        .unwrap();

    let entry = {
        let mut g = box_.lock().unwrap();
        let e = g.try_claim().unwrap();
        assert_eq!(e.attempts, 1);
        assert!(g.is_empty());
        e
    };

    let box_r = box_.clone();
    let entry_c = entry.clone();
    let requeued = thread::spawn(move || {
        let mut g = box_r.lock().unwrap();
        g.requeue(entry_c).is_ok()
    })
    .join()
    .unwrap();
    assert!(requeued);

    let g = box_.lock().unwrap();
    assert_eq!(g.len(), 1);
    assert_eq!(g.pending_under_retry_cap(), 1);
    let again = {
        // Need mut — drop and re-lock
        drop(g);
        let mut g = box_.lock().unwrap();
        g.try_claim().unwrap()
    };
    assert_eq!(again.attempts, 2);
    assert_eq!(again.id, entry.id);
}
