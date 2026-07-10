//! Concurrent LocalOwnershipStore.acquire: exactly one holder wins.

use darkbloom_coordinator::{LocalOwnershipStore, OwnershipError};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[test]
fn concurrent_acquire_exactly_one_holder() {
    let store = Arc::new(LocalOwnershipStore::new(Duration::from_secs(30)));
    let mut handles = Vec::new();
    for i in 0..8 {
        let store = store.clone();
        handles.push(thread::spawn(move || {
            store.acquire(&format!("h{i}")).is_ok()
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1);
    assert!(!store.holder().is_empty());
    // Losers stay blocked until expire.
    assert_eq!(
        store.acquire("other"),
        Err(OwnershipError::AcquireConflict)
    );
}
