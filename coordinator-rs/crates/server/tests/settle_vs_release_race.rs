//! Concurrent settle vs release on the same job: exactly one money move.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_and_release_exactly_one_disposition() {
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
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .map(|applied| applied)
            .unwrap_or(false)
    });
    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        g.release(OperationKey("rel".into()), "j", "a")
            .map(|applied| applied)
            .unwrap_or(false)
    });

    let settled = settle.join().unwrap();
    let released = release.join().unwrap();
    assert!(
        settled ^ released,
        "exactly one of settle/release must apply; settled={settled} released={released}"
    );
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if settled {
        // reserved 1M, charged 400k → refund 600k → 9.6M
        assert_eq!(g.balance("a").0, 9_600_000);
    } else {
        // full release → 10M
        assert_eq!(g.balance("a").0, 10_000_000);
    }
}
