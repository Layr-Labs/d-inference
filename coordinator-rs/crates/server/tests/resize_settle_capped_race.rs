//! Concurrent settle_capped after resize: cap and reservation both bind.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::stream_billing::billable_cap_from_checkpoint;
use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn resize_then_concurrent_settle_capped_by_checkpoint_and_reservation() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 400_000)
            .unwrap();
    }

    let mut cp = ChunkCheckpoint::default();
    cp = match cp.accept(1, 50_000, "h".into()) {
        ChunkAccept::Accepted(next) => next,
        other => panic!("unexpected {other:?}"),
    };
    let cap = billable_cap_from_checkpoint(&cp);
    assert_eq!(cap, 50_000);

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Provider claims 300k; checkpoint cap 50k; reservation 400k → charge 50k
            g.settle_capped(
                OperationKey(format!("sc-{i}")),
                "j",
                "a",
                300_000,
                cap,
                "d-cap",
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
    // reserved 400k, charged 50k → refund 350k → bal = 5M - 400k + 350k = 4.95M
    assert_eq!(g.balance("a").0, 4_950_000);
}
