//! Concurrent MemoryLedger.balance readers during credit/reserve/settle.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_balance_readers_during_lifecycle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock()
        .unwrap()
        .credit("a", 10_000_000, 0)
        .unwrap();

    let led_r = led.clone();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let led = led_r.clone();
            thread::spawn(move || {
                let g = led.lock().unwrap();
                let (b, _) = g.balance("a");
                b
            })
        })
        .collect();

    let led_w = led.clone();
    let writer = thread::spawn(move || {
        let mut g = led_w.lock().unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 250_000, "d")
            .unwrap();
    });

    writer.join().unwrap();
    for h in readers {
        let b = h.join().unwrap();
        // Readers may see 10M, 9M, or 9.75M depending on interleaving
        assert!(
            b == 10_000_000 || b == 9_000_000 || b == 9_750_000,
            "unexpected balance snapshot {b}"
        );
    }
    assert_eq!(led.lock().unwrap().balance("a").0, 9_750_000);
}
