//! Concurrent MemoryTerminalStore.lookup under parallel record.

use darkbloom_coordinator::terminal_ingest::MemoryTerminalStore;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_record_then_lookup() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            s.record(
                &format!("j{i}"),
                &format!("a{i}"),
                &format!("d{i}"),
                "settled",
                None,
            );
            s.lookup(&format!("j{i}"), &format!("a{i}"), &format!("d{i}"))
                .map(|d| d.disposition == "settled")
                .unwrap_or(false)
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }

    let s = store.lock().unwrap();
    for i in 0..8 {
        assert_eq!(
            s.lookup(&format!("j{i}"), &format!("a{i}"), &format!("d{i}"))
                .unwrap()
                .disposition,
            "settled"
        );
    }
}
