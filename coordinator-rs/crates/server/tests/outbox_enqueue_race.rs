//! Concurrent Outbox.enqueue under capacity: no lost ids, no panic.

use darkbloom_coordinator::outbox::Outbox;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_enqueue_unique_ids() {
    let box_ = Arc::new(Mutex::new(Outbox::new(10_000)));
    let mut handles = Vec::new();
    for i in 0..64 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.enqueue("k", &format!("{i}")).unwrap()
        }));
    }
    let mut ids = HashSet::new();
    for h in handles {
        assert!(ids.insert(h.join().unwrap()), "duplicate outbox id");
    }
    assert_eq!(ids.len(), 64);
    assert_eq!(box_.lock().unwrap().len(), 64);
}

#[test]
fn concurrent_enqueue_at_capacity_rejects_cleanly() {
    let box_ = Arc::new(Mutex::new(Outbox::new(8)));
    let mut handles = Vec::new();
    for i in 0..32 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            g.enqueue("k", &format!("{i}")).is_ok()
        }));
    }
    let ok: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|o| *o)
        .count();
    assert_eq!(ok, 8);
    assert_eq!(box_.lock().unwrap().len(), 8);
}
