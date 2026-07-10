//! Concurrent MemoryLedger.settle with empty terminal digest: binds and blocks reuse.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_empty_digest_exactly_one_binds() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle(OperationKey(format!("s-{i}")), "j", "a", 400_000, "")
                .map(|a| a)
                .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    {
        let g = led.lock().unwrap();
        assert_eq!(g.active_job_count(), 0);
        assert_eq!(g.balance("a").0, 4_600_000);
    }

    // Empty digest is bound — another job cannot reuse it.
    {
        let mut g = led.lock().unwrap();
        g.credit("b", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r2".into()), "j2", "b", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j2", "b").unwrap();
        assert!(matches!(
            g.settle(OperationKey("s-other".into()), "j2", "b", 100_000, ""),
            Err(LedgerError::Conflict(_))
        ));
    }
}
