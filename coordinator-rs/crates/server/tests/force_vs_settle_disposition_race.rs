//! Concurrent settle_capped_as force_settled vs settle settled: exactly one disposition.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settled_vs_settled_exactly_one_disposition() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        let mut g = led_f.lock().unwrap();
        g.settle_capped_as(
            OperationKey("force_settle:j".into()),
            "j",
            "a",
            400_000,
            1_000_000,
            "d-force",
            "force_settled",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            400_000,
            "d-settle",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    assert!(forced ^ settled, "exactly one money move");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    let disp = g.job_disposition("j").unwrap();
    assert!(disp == "force_settled" || disp == "settled");
    if forced {
        assert_eq!(disp, "force_settled");
    } else {
        assert_eq!(disp, "settled");
    }
    // reserved 1M, charged 400k → refund 600k → bal = 5M - 1M + 600k = 4.6M
    assert_eq!(g.balance("a").0, 4_600_000);
}
