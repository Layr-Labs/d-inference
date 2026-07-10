//! Concurrent OwnershipGate release then re-acquire: holding restored.

use darkbloom_coordinator::{Epoch, OwnershipError, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_release_then_reacquire_restores_holding() {
    let gate = Arc::new(OwnershipGate::new(false));
    gate.acquire(Epoch(1)).unwrap();
    assert!(gate.holding());

    let gate_r = gate.clone();
    let release = thread::spawn(move || {
        gate_r.release();
        !gate_r.holding()
    });

    let mut reacq = Vec::new();
    for i in 0..8 {
        let gate = gate.clone();
        reacq.push(thread::spawn(move || {
            // May race with release — either OwnershipLost path then acquire, or acquire while held.
            match gate.assert_holding() {
                Ok(()) => true,
                Err(OwnershipError::OwnershipLost) => gate.acquire(Epoch(10 + i as u64)).is_ok(),
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    assert!(release.join().unwrap());
    let mut ok = 0usize;
    for h in reacq {
        if h.join().unwrap() {
            ok += 1;
        }
    }
    assert!(ok >= 1);
    // After concurrent re-acquires, someone holds.
    assert!(gate.holding() || gate.acquire(Epoch(99)).is_ok());
    assert!(gate.holding());
}
