//! Concurrent ExternalEventInbox.observe: exactly one first-apply winner.

use darkbloom_coordinator::external_events::ExternalEventInbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_observe_same_event_exactly_one_applies() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let mut handles = Vec::new();
    for _ in 0..16 {
        let inbox = inbox.clone();
        handles.push(thread::spawn(move || {
            let mut g = inbox.lock().unwrap();
            g.observe("stripe", "evt_race").unwrap()
        }));
    }
    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    assert_eq!(inbox.lock().unwrap().len(), 1);
}
