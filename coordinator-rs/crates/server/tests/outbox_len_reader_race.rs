//! Concurrent MemoryLedger.outbox len readers during enqueue/claim.

use darkbloom_coordinator::outbox::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_outbox_len_readers_during_enqueue_claim() {
    let box_ = Arc::new(Mutex::new(Outbox::new(100)));

    let box_w = box_.clone();
    let writer = thread::spawn(move || {
        let mut g = box_w.lock().unwrap();
        for i in 0..10 {
            g.enqueue("k", &format!("{i}")).unwrap();
        }
        for _ in 0..4 {
            let _ = g.try_claim();
        }
    });

    let box_r = box_.clone();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let box_ = box_r.clone();
            thread::spawn(move || {
                let g = box_.lock().unwrap();
                g.len()
            })
        })
        .collect();

    writer.join().unwrap();
    for h in readers {
        let n = h.join().unwrap();
        assert!(n <= 10, "len={n}");
    }
    assert_eq!(box_.lock().unwrap().len(), 6);
}
