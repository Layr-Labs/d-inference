//! Concurrent ingest_terminal missing identity: MissingIdentity.

use darkbloom_coordinator::terminal_ingest::{
    ingest_terminal, MemoryTerminalStore, TerminalIngest, TerminalIngestError,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_ingest_missing_identity_all_error() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            let (attempt, digest) = if i % 2 == 0 {
                (String::new(), "d".into())
            } else {
                ("a".into(), String::new())
            };
            matches!(
                ingest_terminal(
                    &mut s,
                    TerminalIngest {
                        job_id: "j".into(),
                        attempt_id: attempt,
                        terminal_digest: digest,
                        se_signature: String::new(),
                        outcome: String::new(),
                    },
                ),
                Err(TerminalIngestError::MissingIdentity)
            )
        }));
    }

    let errs: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|e| *e)
        .count();
    assert_eq!(errs, 8);
    assert_eq!(store.lock().unwrap().late_count(), 0);
}
