//! Concurrent token-regression ChunkCheckpoint.accept: Conflict, no advance.

use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_token_regression_is_conflict() {
    let cp = Arc::new(Mutex::new(ChunkCheckpoint {
        last_sequence: 5,
        completion_tokens: 50,
        rolling_hash: "h5".into(),
    }));

    let mut handles = Vec::new();
    for i in 0..8u64 {
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let g = cp.lock().unwrap();
            // Newer sequence but fewer tokens → Conflict.
            match g.accept(6 + i, 10, format!("reg-{i}")) {
                ChunkAccept::Conflict => true,
                ChunkAccept::Stale => false,
                ChunkAccept::Accepted(_) => panic!("token regression must not accept"),
            }
        }));
    }

    let mut conflicts = 0usize;
    for h in handles {
        if h.join().unwrap() {
            conflicts += 1;
        }
    }
    assert_eq!(conflicts, 8);
    let g = cp.lock().unwrap();
    assert_eq!(g.last_sequence, 5);
    assert_eq!(g.completion_tokens, 50);
}
