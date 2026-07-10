//! Concurrent Outbox.requeue when full: Full error.

use darkbloom_coordinator::outbox::{Outbox, OutboxError};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_requeue_when_full_rejects() {
    let box_ = Arc::new(Mutex::new(Outbox::new(2)));
    let entry = {
        let mut g = box_.lock().unwrap();
        g.enqueue("a", "{}").unwrap();
        g.enqueue("b", "{}").unwrap();
        // Claim one into in_flight; occupied stays 2 so further enqueue is Full.
        let e = g.try_claim().unwrap();
        assert_eq!(g.enqueue("c", "{}"), Err(OutboxError::Full));
        e
    };

    // First requeue of the claimed entry succeeds (frees in_flight then pushes pending).
    // Concurrent clones of the same entry then see a full queue.
    let mut handles = Vec::new();
    for _ in 0..4 {
        let box_ = box_.clone();
        let entry = entry.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            match g.requeue(entry) {
                Err(OutboxError::Full) => "full",
                Ok(()) => "ok",
                Err(e) => panic!("unexpected {e}"),
            }
        }));
    }

    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    let oks = results.iter().filter(|r| **r == "ok").count();
    let fulls = results.iter().filter(|r| **r == "full").count();
    assert_eq!(oks, 1);
    assert_eq!(fulls, 3);
    assert_eq!(box_.lock().unwrap().len(), 2);
}
