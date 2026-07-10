//! Concurrent OwnershipGate.release then assert_holding: OwnershipLost.

use darkbloom_coordinator::{Epoch, OwnershipError, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_release_then_assert_holding_lost() {
    let gate = Arc::new(OwnershipGate::new(false));
    gate.acquire(Epoch(1)).unwrap();
    assert!(gate.holding());

    let gate_r = gate.clone();
    let release = thread::spawn(move || {
        gate_r.release();
    });
    let gate_a = gate.clone();
    let assert_t = thread::spawn(move || {
        // May race before or after release.
        gate_a.assert_holding()
    });

    release.join().unwrap();
    let _ = assert_t.join().unwrap(); // either Ok or OwnershipLost depending on race
    // After join of release, holding must be false.
    assert!(!gate.holding());
    assert_eq!(gate.assert_holding(), Err(OwnershipError::OwnershipLost));
}

#[test]
fn concurrent_assert_holding_while_holding_all_ok() {
    let gate = Arc::new(OwnershipGate::new(false));
    gate.acquire(Epoch(7)).unwrap();
    let mut handles = Vec::new();
    for _ in 0..16 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || gate.assert_holding().is_ok()));
    }
    let oks: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|o| *o)
        .count();
    assert_eq!(oks, 16);
    assert_eq!(gate.epoch(), Epoch(7));
}
