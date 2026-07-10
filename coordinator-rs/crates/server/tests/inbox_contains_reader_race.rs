//! Concurrent MemoryLedger.ExternalEventInbox.contains under parallel observe.

use darkbloom_coordinator::external_events::ExternalEventInbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_contains_readers_during_observe() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));

    let inbox_w = inbox.clone();
    let writer = thread::spawn(move || {
        let mut g = inbox_w.lock().unwrap();
        for i in 0..8 {
            assert!(g.observe("stripe", &format!("e{i}"), "d").unwrap());
        }
    });

    let inbox_r = inbox.clone();
    let readers: Vec<_> = (0..8)
        .map(|i| {
            let inbox = inbox_r.clone();
            thread::spawn(move || {
                let g = inbox.lock().unwrap();
                g.contains("stripe", &format!("e{i}"))
            })
        })
        .collect();

    writer.join().unwrap();
    // After writer completes, all contains should be true if readers run after;
    // if before, may be false. Collect without asserting each.
    let mut any_true = false;
    for h in readers {
        if h.join().unwrap() {
            any_true = true;
        }
    }
    // At least after join of writer, inbox has all 8
    assert_eq!(inbox.lock().unwrap().len(), 8);
    for i in 0..8 {
        assert!(inbox.lock().unwrap().contains("stripe", &format!("e{i}")));
    }
    let _ = any_true;
}
