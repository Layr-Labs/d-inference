//! Stream billing checkpoint → settle_capped: cap never exceeds reservation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::stream_billing::billable_cap_from_checkpoint;
use darkbloom_core::ChunkCheckpoint;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_from_checkpoint_never_overcharges() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    // Checkpoint reports more tokens than reservation can cover (1µUSD/token).
    let mut cp = ChunkCheckpoint::default();
    cp = match cp.accept(1, 50_000, "h".into()) {
        darkbloom_core::ChunkAccept::Accepted(next) => next,
        other => panic!("unexpected {other:?}"),
    };
    let cap = billable_cap_from_checkpoint(&cp);
    assert_eq!(cap, 50_000);

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle_capped(
                OperationKey(format!("sc:{i}")),
                "j",
                "a",
                50_000, // actual tokens-as-µUSD
                cap,
                "stream-d",
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }

    let mut wins = 0usize;
    for h in handles {
        if h.join().unwrap() {
            wins += 1;
        }
    }
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Cap clamps to reservation 1000 → charge 1000, refund 0 → bal = 10M - 1000
    assert_eq!(g.balance("a").0, 9_999_000);
}
