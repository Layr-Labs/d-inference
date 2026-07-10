//! Concurrent MemoryLedger.credit: balances accumulate without lost updates.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_credit_accumulates_exactly() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    let mut handles = Vec::new();
    for _ in 0..32 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000, 100).unwrap();
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a"), (32_000, 3_200));
}

#[test]
fn concurrent_credit_rejects_invalid_without_partial_apply() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 10_000, 0).unwrap();
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            if i % 2 == 0 {
                match g.credit("a", 500, 50) {
                    Ok(()) => Some(true),
                    Err(_) => Some(false),
                }
            } else {
                match g.credit("a", 100, 200) {
                    Err(LedgerError::Conflict(_)) => None, // expected reject
                    Ok(()) => Some(true),                 // unexpected apply
                    Err(_) => Some(false),
                }
            }
        }));
    }
    let mut applied = 0usize;
    let mut rejected = 0usize;
    for h in handles {
        match h.join().unwrap() {
            Some(true) => applied += 1,
            Some(false) => panic!("unexpected credit outcome"),
            None => rejected += 1,
        }
    }
    assert_eq!(applied, 8);
    assert_eq!(rejected, 8);
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a"), (10_000 + 8 * 500, 8 * 50));
}
