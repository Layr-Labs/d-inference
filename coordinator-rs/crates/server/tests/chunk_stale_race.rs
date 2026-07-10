//! Concurrent older-sequence ChunkCheckpoint.accept: Stale never advances.

use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_stale_sequences_never_advance() {
    let cp = Arc::new(Mutex::new(ChunkCheckpoint {
        last_sequence: 10,
        completion_tokens: 100,
        rolling_hash: "h10".into(),
    }));

    let mut handles = Vec::new();
    for i in 1..=8u64 {
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let g = cp.lock().unwrap();
            match g.accept(i, i * 10, format!("old-{i}")) {
                ChunkAccept::Stale => true,
                ChunkAccept::Conflict => false,
                ChunkAccept::Accepted(_) => panic!("older sequence must not accept"),
            }
        }));
    }

    let mut stale = 0usize;
    for h in handles {
        if h.join().unwrap() {
            stale += 1;
        }
    }
    assert_eq!(stale, 8);
    let g = cp.lock().unwrap();
    assert_eq!(g.last_sequence, 10);
    assert_eq!(g.completion_tokens, 100);
}
