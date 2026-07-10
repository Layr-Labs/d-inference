//! Concurrent OwnershipGate.acquire after refuse_on_rust with recovery.

use darkbloom_coordinator::{Epoch, OwnershipGate};
use std::sync::Arc;
use std::thread;

#[test]
fn concurrent_acquire_after_recovery_mode_all_ok() {
    let gate = Arc::new(OwnershipGate::new(true));
    gate.set_rust_active(true);
    gate.enable_recovery_mode();

    let mut handles = Vec::new();
    for i in 1..=8u64 {
        let gate = gate.clone();
        handles.push(thread::spawn(move || {
            gate.acquire(Epoch(i)).is_ok()
        }));
    }

    let oks: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|o| *o)
        .count();
    assert_eq!(oks, 8);
    assert!(gate.holding());
    let e = gate.epoch().0;
    assert!((1..=8).contains(&e));
}
