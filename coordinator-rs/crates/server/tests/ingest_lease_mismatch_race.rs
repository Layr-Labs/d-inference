//! Concurrent ingest with wrong lease_id never ACKs settled (DECISIONS #53).

use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_wrong_lease_all_conflict() {
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    {
        let mut s = store.lock().unwrap();
        s.record_bound("j", "a1", "d1", "settled", None, "lease-real", "sig1");
    }

    let mut handles = Vec::new();
    for i in 0..16 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            let ack = ingest_terminal(
                &mut s,
                TerminalIngest {
                    job_id: "j".into(),
                    attempt_id: "a1".into(),
                    terminal_digest: "d1".into(),
                    lease_id: format!("lease-attacker-{i}"),
                    se_signature: "sig1".into(),
                    outcome: String::new(),
                },
            )
            .unwrap();
            ack["disposition"] == "conflict"
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
    assert_eq!(store.lock().unwrap().late_count(), 0);
}
