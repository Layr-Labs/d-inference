//! Concurrent same-sequence ChunkCheckpoint.accept: Conflict never advances tokens.

use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_same_sequence_conflict_does_not_advance() {
    let cp = Arc::new(Mutex::new(ChunkCheckpoint {
        last_sequence: 1,
        completion_tokens: 10,
        rolling_hash: "h1".into(),
    }));

    let mut handles = Vec::new();
    for i in 0..8 {
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let g = cp.lock().unwrap();
            // Same sequence, different hash → Conflict (must not mutate).
            match g.accept(1, 10 + i, format!("bad-{i}")) {
                ChunkAccept::Conflict => true,
                ChunkAccept::Stale => false,
                ChunkAccept::Accepted(_) => panic!("must not accept conflicting sequence"),
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
    assert_eq!(g.last_sequence, 1);
    assert_eq!(g.completion_tokens, 10);
    assert_eq!(g.rolling_hash, "h1");
}
