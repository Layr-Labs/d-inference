//! Concurrent MemoryLedger.terminal ingest after settle records known disposition.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn settle_records_terminal_then_concurrent_ingest() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g
            .settle(OperationKey("s".into()), "j", "a", 200_000, "td-known")
            .unwrap());
    }
    {
        let mut s = store.lock().unwrap();
        s.record("att-1", "td-known", "settled", None);
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            let mut s = store.lock().unwrap();
            ingest_terminal(
                &mut s,
                TerminalIngest {
                    job_id: "j".into(),
                    attempt_id: "att-1".into(),
                    terminal_digest: "td-known".into(),
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
        assert_eq!(ack["type"], "terminal_ack");
    }
    assert_eq!(store.lock().unwrap().late_count(), 0);
    assert_eq!(led.lock().unwrap().balance("a").0, 4_800_000);
}
