//! Concurrent MemoryLedger.credit negative amounts: all InvalidAmount.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_credit_negative_all_invalid() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 1_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let (total, wdr) = if i % 2 == 0 { (-1, 0) } else { (100, -1) };
            matches!(
                g.credit("a", total, wdr),
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
    assert_eq!(led.lock().unwrap().balance("a"), (1_000, 0));
}
