//! Concurrent cancel-style release vs settle after start_authorized.
//! Release must always fail (DECISIONS #16); settle clears the hold.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cancel_release_vs_settle_after_start_authorized() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            400_000,
            "cancel-settle-d",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected settle: {e}"),
        }
    });

    let mut release_handles = Vec::new();
    for i in 0..8 {
        let led_r = led.clone();
        release_handles.push(thread::spawn(move || {
            let mut g = led_r.lock().unwrap();
            // Mirrors cancel_before_or_after_content pre-start release key shape.
            match g.release(
                OperationKey(format!("cancel_release:j:{i}")),
                "j",
                "a",
            ) {
                Ok(applied) => applied,
                Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected release: {e}"),
            }
        }));
    }

    let settled = settle.join().unwrap();
    let mut released = 0usize;
    for h in release_handles {
        if h.join().unwrap() {
            released += 1;
        }
    }

    assert_eq!(released, 0, "cancel release must never succeed after start_authorized");
    assert!(settled, "settle must clear the hold");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // reserved 1M, charged 400k → refund 600k → bal = 10M - 1M + 600k = 9.6M
    assert_eq!(g.balance("a").0, 9_600_000);
}
