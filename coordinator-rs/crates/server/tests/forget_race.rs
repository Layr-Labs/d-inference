//! Concurrent ExternalEventInbox.forget vs observe: forget unblocks retry.

use darkbloom_coordinator::external_events::ExternalEventInbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn after_forget_concurrent_observe_exactly_one_wins() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    {
        let mut g = inbox.lock().unwrap();
        assert!(g.observe("stripe", "evt_f").unwrap());
        assert!(g.forget("stripe", "evt_f"));
        assert!(!g.contains("stripe", "evt_f"));
    }

    let mut handles = Vec::new();
    for _ in 0..16 {
        let inbox = inbox.clone();
        handles.push(thread::spawn(move || {
            let mut g = inbox.lock().unwrap();
            g.observe("stripe", "evt_f").unwrap()
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

#[test]
fn forget_missing_key_is_false() {
    let mut inbox = ExternalEventInbox::new();
    assert!(!inbox.forget("stripe", "missing"));
}
