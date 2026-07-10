//! Concurrent ExternalEventInbox.observe distinct sources same event_id.

use darkbloom_coordinator::external_events::ExternalEventInbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_observe_distinct_sources_same_event_id() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let mut handles = Vec::new();
    for i in 0..8 {
        let inbox = inbox.clone();
        let source = if i % 2 == 0 { "stripe" } else { "connect" };
        handles.push(thread::spawn(move || {
            let mut g = inbox.lock().unwrap();
            g.observe(source, "evt_shared", "d").unwrap()
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    // Two sources × first observe each = 2 wins; rest are replays within source.
    assert_eq!(wins, 2);
    let g = inbox.lock().unwrap();
    assert_eq!(g.len(), 2);
    assert!(g.contains("stripe", "evt_shared"));
    assert!(g.contains("connect", "evt_shared"));
}
