//! Concurrent MemoryLedger.reserve zero/negative amount: all InvalidAmount.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_invalid_amount_all_reject() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 5_000_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let amount = if i % 2 == 0 { 0 } else { -100 };
            matches!(
                g.reserve(
                    OperationKey(format!("r-{i}")),
                    &format!("j-{i}"),
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
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 5_000_000);
}
