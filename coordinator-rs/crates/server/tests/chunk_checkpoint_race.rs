//! Concurrent ChunkCheckpoint.accept: only monotonic advances bill.

use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_checkpoint_accept_never_regresses_tokens() {
    let cp = Arc::new(Mutex::new(ChunkCheckpoint::default()));
    let mut handles = Vec::new();
    for i in 1..=16u64 {
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let mut g = cp.lock().unwrap();
            match g.accept(i, i * 10, format!("h{i}")) {
                ChunkAccept::Accepted(next) => {
                    *g = next;
                    true
                }
                ChunkAccept::Stale | ChunkAccept::Conflict => false,
            }
        }));
    }
    let mut accepted = 0usize;
    for h in handles {
        if h.join().unwrap() {
            accepted += 1;
        }
    }
    assert!(accepted >= 1);
    let g = cp.lock().unwrap();
    assert!(g.last_sequence >= 1);
    assert_eq!(g.completion_tokens, g.last_sequence * 10);
}
