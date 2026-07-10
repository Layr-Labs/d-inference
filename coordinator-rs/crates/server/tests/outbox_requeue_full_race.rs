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
        // Claim one so we have an entry to requeue, then fill again
        let e = g.try_claim().unwrap();
        g.enqueue("c", "{}").unwrap(); // queue full again (1 remaining + new = 2)
        e
    };

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
    // At most one requeue can succeed if a slot frees; with full queue of 2
    // and no claims, all should be Full. But first requeue might succeed if
    // len < max after claim left a slot that was refilled...
    // After setup: claimed 1 (len=1), enqueued c (len=2 full). Requeue of
    // claimed entry: first succeeds (len=3? No max=2 so Full).
    // Wait: after claim len=1, enqueue c len=2. requeue pushes back → would be 3 > max → Full.
    // So all Full.
    assert!(results.iter().all(|r| *r == "full"));
    assert_eq!(box_.lock().unwrap().len(), 2);
}
