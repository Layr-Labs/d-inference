//! Concurrent MemoryTerminalStore.record then ingest preferred ack payload.

use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use serde_json::json;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_ingest_prefers_stored_ack_payload() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    let custom = json!({"type":"terminal_ack","custom":true,"v":1});
    {
        let mut s = store.lock().unwrap();
        s.record("j1", "a1", "d1", "settled", Some(custom.clone()));
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let store = store.clone();
        let custom = custom.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            let ack = ingest_terminal(
                &mut s,
                TerminalIngest {
                    job_id: "j1".into(),
                    attempt_id: "a1".into(),
                    terminal_digest: "d1".into(),
                    se_signature: String::new(),
                    outcome: String::new(),
                },
            )
            .unwrap();
            ack == custom
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(store.lock().unwrap().late_count(), 0);
}
