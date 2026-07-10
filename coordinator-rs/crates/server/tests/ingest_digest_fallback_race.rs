//! Concurrent ingest with attempt_id drift: digest-only fallback ACKs settled.

use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_ingest_digest_fallback_never_late() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    store.lock().unwrap().record("", "d-fb", "settled", None);

    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut g = store.lock().unwrap();
            let ack = ingest_terminal(
                &mut g,
                TerminalIngest {
                    job_id: "j".into(),
                    attempt_id: format!("attempt-{i}"),
                    terminal_digest: "d-fb".into(),
                    se_signature: String::new(),
                    outcome: "ok".into(),
                },
            )
            .unwrap();
            ack["disposition"] == "settled"
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(store.lock().unwrap().late_count(), 0);
}
