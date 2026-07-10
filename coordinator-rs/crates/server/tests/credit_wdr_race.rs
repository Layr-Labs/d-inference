//! Concurrent MemoryLedger.credit with withdrawable provenance under race.

use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_credit_withdrawable_provenance_accumulates() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    let mut handles = Vec::new();
    for _ in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Mix of deposit-like (full wdr) and earnings-like (zero wdr) credits.
            g.credit("a", 1_000, 1_000).unwrap();
            g.credit("a", 500, 0).unwrap();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    let g = led.lock().unwrap();
    // 16 * (1000+500) = 24_000 total; 16 * 1000 = 16_000 withdrawable
    assert_eq!(g.balance("a"), (24_000, 16_000));
}
