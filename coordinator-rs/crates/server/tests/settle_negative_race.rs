//! Concurrent MemoryLedger.settle with negative actual: all InvalidAmount.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_negative_actual_all_invalid() {
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
            matches!(
                g.settle(
                    OperationKey(format!("s-{i}")),
                    "j",
                    "a",
                    -1,
                    &format!("d-{i}"),
                ),
                Err(LedgerError::InvalidAmount)
            )
        }));
    }

    let invalids: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|v| *v)
        .count();
    assert_eq!(invalids, 8);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 4_000_000);
}
