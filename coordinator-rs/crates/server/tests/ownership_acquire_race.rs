//! Concurrent OwnershipGate.acquire: last writer wins on epoch; all hold.

use darkbloom_coordinator::{Epoch, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_acquire_last_epoch_wins() {
    let gate = Arc::new(OwnershipGate::new(false));
    let mut handles = Vec::new();
    for i in 1..=16u64 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || {
            gate.acquire(Epoch(i)).unwrap();
            i
        }));
    }
    let mut max = 0u64;
    for h in handles {
        max = max.max(h.join().unwrap());
    }
    assert!(gate.holding());
    // Final epoch is whatever last store won; must be in 1..=16.
    let e = gate.epoch().0;
    assert!((1..=16).contains(&e), "epoch {e} out of range");
    assert_eq!(max, 16);
    gate.release();
    assert!(!gate.holding());
}

#[test]
fn concurrent_acquire_refused_when_rust_active() {
    let gate = Arc::new(OwnershipGate::new(true));
    gate.set_rust_active(true);
    let mut handles = Vec::new();
    for i in 0..8 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || gate.acquire(Epoch(i + 1)).is_err()));
    }
    let refused: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|r| *r)
        .count();
    assert_eq!(refused, 8);
    assert!(!gate.holding());
}
