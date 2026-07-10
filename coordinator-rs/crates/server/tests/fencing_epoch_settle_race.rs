//! Concurrent require_fencing_epoch: mismatch is OwnershipLost (DECISIONS #52).

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_fencing_epoch_mismatch_never_settles() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j-ep", "a", 200_000)
            .unwrap();
        g.bind_fencing_epoch("j-ep", 9).unwrap();
        g.mark_start_authorized("j-ep", "a").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let epoch = if i % 2 == 0 { 9 } else { 10 };
            match g.require_fencing_epoch("j-ep", epoch) {
                Ok(()) => {
                    // Only epoch 9 may settle.
                    g.settle_capped(
                        OperationKey(format!("s-{i}")),
                        "j-ep",
                        "a",
                        50_000,
                        50_000,
                        &format!("d-{i}"),
                    )
                    .map(|ok| if ok { "settled" } else { "noop" })
                    .unwrap_or("settle_err")
                }
                Err(LedgerError::OwnershipLost) => "epoch_lost",
                Err(_) => "other",
            }
            .to_string()
        }));
    }

    let mut settled = 0usize;
    let mut epoch_lost = 0usize;
    let mut settle_err = 0usize;
    for h in handles {
        match h.join().unwrap().as_str() {
            "settled" => settled += 1,
            "epoch_lost" => epoch_lost += 1,
            "settle_err" | "noop" => settle_err += 1,
            other => panic!("unexpected {other}"),
        }
    }
    assert_eq!(settled, 1, "exactly one epoch-9 settle");
    assert!(epoch_lost >= 1, "epoch-10 callers must see OwnershipLost");
    let _ = settle_err; // remaining epoch-9 callers after dispose
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 4_950_000); // 5M - 50k charge (200k reserve, 150k refunded)
}
