//! Concurrent OwnershipGate acquire in recovery mode while rust_active.

use darkbloom_coordinator::{Epoch, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_recovery_mode_acquire_while_rust_active() {
    let gate = Arc::new(OwnershipGate::new(true));
    gate.set_rust_active(true);
    // Without recovery mode, acquire must fail.
    assert!(gate.acquire(Epoch(1)).is_err());

    gate.enable_recovery_mode();

    let mut handles = Vec::new();
    for i in 0..8 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || gate.acquire(Epoch(10 + i)).is_ok()));
    }
    let mut ok = 0usize;
    for h in handles {
        if h.join().unwrap() {
            ok += 1;
        }
    }
    assert_eq!(ok, 8, "recovery mode allows acquire despite rust_active");
    assert!(gate.holding());
    assert!(gate.epoch().0 >= 10);
}
