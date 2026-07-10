//! Concurrent MemoryLedger.resize_and_authorize zero/negative: all InvalidAmount.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_invalid_amount_all_reject() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let amount = if i % 2 == 0 { 0 } else { -50 };
            matches!(
                g.resize_and_authorize(
                    OperationKey(format!("ra-{i}")),
                    "j",
                    "a",
                    amount,
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
    assert!(!g.job_funded_start("j"));
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 4_000_000);
}
