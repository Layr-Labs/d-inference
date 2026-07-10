//! Concurrent Outbox.try_claim on empty queue: all None.

use darkbloom_coordinator::outbox::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_try_claim_empty_all_none() {
    let box_ = Arc::new(Mutex::new(Outbox::new(10)));
    let mut handles = Vec::new();
    for _ in 0..8 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.try_claim().is_none()
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
    assert!(box_.lock().unwrap().is_empty());
}
