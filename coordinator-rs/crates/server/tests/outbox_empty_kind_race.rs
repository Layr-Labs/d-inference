//! Concurrent Outbox.enqueue empty kind: InvalidKind.

use darkbloom_coordinator::outbox::{Outbox, OutboxError};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_enqueue_empty_kind_all_invalid() {
    let box_ = Arc::new(Mutex::new(Outbox::new(100)));
    let mut handles = Vec::new();
    for i in 0..8 {
        let box_ = box_.clone();
        handles.push(thread::spawn(move || {
            let mut g = box_.lock().unwrap();
            matches!(
                g.enqueue("", &format!("{i}")),
                Err(OutboxError::InvalidKind)
            )
        }));
    }

    let invalids: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|v| *v)
        .count();
    assert_eq!(invalids, 8);
    assert!(box_.lock().unwrap().is_empty());
}
