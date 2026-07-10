//! Concurrent MemoryLedger.release must not over-credit.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_same_op_key_is_idempotent() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0);
        g.reserve(OperationKey("r".into()), "j", "a", 4_000_000)
            .unwrap();
    }
    let mut handles = Vec::new();
    for _ in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.release(OperationKey("rel".into()), "j", "a").unwrap()
        }));
    }
    let applied: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(applied, 1, "exactly one release must apply");
    assert_eq!(led.lock().unwrap().balance("a").0, 10_000_000);
}
