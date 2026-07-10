//! Concurrent MemoryTerminalStore.late_count under parallel late ingest.

use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_late_ingest_increments_late_count() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            let ack = ingest_terminal(
                &mut s,
                TerminalIngest {
                    job_id: format!("j{i}"),
                    attempt_id: format!("a{i}"),
                    terminal_digest: format!("d{i}"),
                    se_signature: String::new(),
                    outcome: String::new(),
                },
            )
            .unwrap();
            ack["disposition"] == "late"
        }));
    }

    let lates: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|l| *l)
        .count();
    assert_eq!(lates, 8);
    assert_eq!(store.lock().unwrap().late_count(), 8);
}
