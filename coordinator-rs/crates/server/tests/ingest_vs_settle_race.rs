//! Concurrent ingest_terminal vs settle: ingest never moves money.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_ingest_and_settle_ingest_never_moves_money() {
    let ledger = Arc::new(Mutex::new(MemoryLedger::default()));
    let store = Arc::new(Mutex::new(MemoryTerminalStore::new()));
    {
        let mut g = ledger.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }
    // Pre-record disposition so ingest returns settled ACK (no late).
    {
        let mut s = store.lock().unwrap();
        s.record("att-1", "td-1", "settled", None);
    }

    let led_s = ledger.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "td-settle")
            .map(|a| a)
            .unwrap_or(false)
    });
    let store_i = store.clone();
    let ingest = thread::spawn(move || {
        let mut s = store_i.lock().unwrap();
        ingest_terminal(
            &mut s,
            TerminalIngest {
                job_id: "j".into(),
                attempt_id: "att-1".into(),
                terminal_digest: "td-1".into(),
                se_signature: String::new(),
                outcome: String::new(),
            },
        )
        .unwrap()
    });

    let settled = settle.join().unwrap();
    let ack = ingest.join().unwrap();
    assert!(settled);
    assert_eq!(ack["disposition"], "settled");
    assert_eq!(store.lock().unwrap().late_count(), 0);
    let g = ledger.lock().unwrap();
    // Ingest must not have credited/debited — only settle moved money.
    assert_eq!(g.balance("a").0, 9_600_000);
    assert_eq!(g.active_job_count(), 0);
}
