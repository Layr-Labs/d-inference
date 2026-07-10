//! Concurrent MemoryLedger.ExternalEventInbox.len under parallel observe.

use darkbloom_coordinator::external_events::ExternalEventInbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_inbox_len_tracks_distinct_observes() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let mut handles = Vec::new();
    for i in 0..16 {
        let inbox = inbox.clone();
        handles.push(thread::spawn(move || {
            let mut g = inbox.lock().unwrap();
            g.observe("stripe", &format!("e{i}"), "d").unwrap()
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 16);
    assert_eq!(inbox.lock().unwrap().len(), 16);
    assert!(!inbox.lock().unwrap().is_empty());
}
