//! Concurrent ChunkPipe sequences + checkpoint accept; settle_capped uses final cap.

use darkbloom_coordinator::chunk_pipe::{bounded_chunk_pipe, SequencedChunk};
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::stream_billing::{accept_pipe_chunk, billable_cap_from_checkpoint};
use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use bytes::Bytes;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_pipe_sequences_checkpoint_then_settle() {
    let (pipe, _r) = bounded_chunk_pipe(64, 1 << 20);
    let pipe = Arc::new(pipe);
    let cp = Arc::new(Mutex::new(ChunkCheckpoint::default()));

    let mut handles = Vec::new();
    for i in 0..8u64 {
        let pipe = pipe.clone();
        let cp = cp.clone();
        handles.push(thread::spawn(move || {
            let seq = pipe
                .try_send(Bytes::copy_from_slice(format!("c{i}").as_bytes()))
                .unwrap();
            let mut g = cp.lock().unwrap();
            if let ChunkAccept::Accepted(next) = accept_pipe_chunk(
                &g,
                &SequencedChunk {
                    sequence: seq,
                    bytes: Bytes::new(),
                },
                seq * 100,
                format!("h{seq}"),
            ) {
                *g = next;
            }
            seq
        }));
    }

    let mut seqs: Vec<u64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    seqs.sort();
    assert_eq!(seqs, (1..=8).collect::<Vec<_>>());

    let snap = cp.lock().unwrap().clone();
    let cap = billable_cap_from_checkpoint(&snap);
    assert_eq!(cap, snap.last_sequence as i64 * 100);
    assert!(snap.last_sequence >= 1);

    let reserved = 10_000i64;
    let mut led = MemoryLedger::default();
    led.credit("a", 10_000_000, 0).unwrap();
    led.reserve(OperationKey("r".into()), "j", "a", reserved)
        .unwrap();
    led.mark_start_authorized("j").unwrap();
    let charge = cap.min(reserved);
    assert!(led
        .settle_capped(OperationKey("s".into()), "j", "a", cap, cap, "pipe-d")
        .unwrap());
    assert_eq!(led.balance("a").0, 10_000_000 - charge);
}
