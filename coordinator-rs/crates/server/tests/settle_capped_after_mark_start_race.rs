//! Concurrent settle_capped after mark_start with checkpoint below reservation.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::stream_billing::billable_cap_from_checkpoint;
use darkbloom_core::{ChunkAccept, ChunkCheckpoint};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_after_mark_start_uses_checkpoint() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 500_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let mut cp = ChunkCheckpoint::default();
    cp = match cp.accept(1, 75_000, "h".into()) {
        ChunkAccept::Accepted(next) => next,
        other => panic!("unexpected {other:?}"),
    };
    let cap = billable_cap_from_checkpoint(&cp);
    assert_eq!(cap, 75_000);

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle_capped(
                OperationKey(format!("sc-{i}")),
                "j",
                "a",
                400_000,
                cap,
                "d-ms",
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
    // charged min(400k, 75k, 500k) = 75k → refund 425k → bal = 5M - 500k + 425k = 4.925M
    assert_eq!(g.balance("a").0, 4_925_000);
}
