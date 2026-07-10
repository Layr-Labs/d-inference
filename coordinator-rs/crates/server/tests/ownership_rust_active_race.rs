//! Concurrent OwnershipGate.set_rust_active and check_startup.

use darkbloom_coordinator::{OwnershipError, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_set_rust_active_and_check_startup() {
    let gate = Arc::new(OwnershipGate::new(true));

    let gate_s = gate.clone();
    let setter = thread::spawn(move || {
        gate_s.set_rust_active(true);
    });

    let gate_c = gate.clone();
    let checker = thread::spawn(move || gate_c.check_startup());

    setter.join().unwrap();
    let _ = checker.join().unwrap(); // may race before or after set

    // After setter completes, refuse must hold.
    assert_eq!(gate.check_startup(), Err(OwnershipError::UnsafeStartup));
}

#[test]
fn recovery_mode_allows_check_after_rust_active() {
    let gate = Arc::new(OwnershipGate::new(true));
    gate.set_rust_active(true);
    assert_eq!(gate.check_startup(), Err(OwnershipError::UnsafeStartup));

    let mut handles = Vec::new();
    for _ in 0..4 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || {
            gate.enable_recovery_mode();
            gate.check_startup().is_ok()
        }));
    }
    for h in handles {
        assert!(h.join().unwrap());
    }
}
