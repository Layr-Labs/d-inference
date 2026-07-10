//! Concurrent MemoryLedger.outbox pending_under_retry_cap under claim/requeue.

use darkbloom_coordinator::outbox::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_pending_under_retry_cap_tracks_claims() {
    let box_ = Arc::new(Mutex::new(Outbox::new(100)));
    {
        let mut g = box_.lock().unwrap();
        for i in 0..10 {
            g.enqueue("k", &format!("{i}")).unwrap();
        }
        assert_eq!(g.pending_under_retry_cap(), 10);
    }

    let mut handles = Vec::new();
    for _ in 0..5 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.try_claim().is_some()
        }));
    }

    let claimed: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|c| *c)
        .count();
    assert_eq!(claimed, 5);
    // Claims are non-destructive until ack — occupied count stays 10.
    assert_eq!(box_.lock().unwrap().len(), 10);
    assert_eq!(box_.lock().unwrap().pending_under_retry_cap(), 10);
    assert_eq!(box_.lock().unwrap().in_flight_len(), 5);
}
