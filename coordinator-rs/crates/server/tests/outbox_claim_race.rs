//! Concurrent outbox try_claim: each entry claimed at most once.

use darkbloom_coordinator::outbox::Outbox;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_try_claim_no_duplicate_ids() {
    let box_ = Arc::new(Mutex::new(Outbox::new(1000)));
    {
        let mut g = box_.lock().unwrap();
        for i in 0..64 {
            g.enqueue("k", &format!("{i}")).unwrap();
        }
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut ids = Vec::new();
            loop {
                let mut g = box_.lock().unwrap();
                match g.try_claim() {
                    Some(e) => ids.push(e.id),
                    None => break,
                }
            }
            ids
        }));
    }

    let mut all = HashSet::new();
    for h in handles {
        for id in h.join().unwrap() {
            assert!(all.insert(id), "duplicate claim of outbox id {id}");
        }
    }
    assert_eq!(all.len(), 64);
    assert!(box_.lock().unwrap().is_empty());
}
