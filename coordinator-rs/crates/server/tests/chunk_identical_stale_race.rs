//! Concurrent identical ChunkCheckpoint replay: Stale, no advance.

use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_identical_replay_is_stale() {
    let cp = Arc::new(Mutex::new(ChunkCheckpoint {
        last_sequence: 3,
        completion_tokens: 30,
        rolling_hash: "h3".into(),
    }));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let g = cp.lock().unwrap();
            match g.accept(3, 30, "h3".into()) {
                ChunkAccept::Stale => true,
                ChunkAccept::Conflict => false,
                ChunkAccept::Accepted(_) => panic!("identical replay must be Stale"),
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
    assert_eq!(g.last_sequence, 3);
    assert_eq!(g.completion_tokens, 30);
}
