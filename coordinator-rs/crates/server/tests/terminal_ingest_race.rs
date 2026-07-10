//! Concurrent ingest_terminal: known disposition never double-settles; late is unique.

use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_ingest_known_terminal_always_settled_ack() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    {
        let mut g = store.lock().unwrap();
        g.record("a1", "d1", "settled", None);
    }
    let mut handles = Vec::new();
    for _ in 0..16 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut g = store.lock().unwrap();
            ingest_terminal(
                &mut g,
                TerminalIngest {
                    job_id: "j1".into(),
                    attempt_id: "a1".into(),
                    terminal_digest: "d1".into(),
                    se_signature: String::new(),
                    outcome: String::new(),
                },
            )
            .unwrap()
        }));
    }
    for h in handles {
        let ack = h.join().unwrap();
        assert_eq!(ack["disposition"], "settled");
    }
    assert_eq!(store.lock().unwrap().late_count(), 0);
}

#[test]
fn concurrent_ingest_unknown_records_late_once_per_call() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut g = store.lock().unwrap();
            ingest_terminal(
                &mut g,
                TerminalIngest {
                    job_id: "j".into(),
                    attempt_id: format!("a{i}"),
                    terminal_digest: format!("d{i}"),
                    se_signature: String::new(),
                    outcome: String::new(),
                },
            )
            .unwrap()
        }));
    }
    for h in handles {
        assert_eq!(h.join().unwrap()["disposition"], "late");
    }
    assert_eq!(store.lock().unwrap().late_count(), 8);
}
