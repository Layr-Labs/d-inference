//! Concurrent settle_capped vs recover on reserved-only job: XOR.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_capped_vs_recover_on_reserved_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 220_000)
            .unwrap();
    }

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            100_000,
            40_000,
            "d-sc-rsv",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let led_r = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_r, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let capped_ok = capped.join().unwrap();
    let released = recover.join().unwrap();
    assert!(capped_ok ^ released, "exactly one must win");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if capped_ok {
        // charged min(100k, 40k, 220k) = 40k → refund 180k → bal = 5M - 220k + 180k = 4.96M
        assert_eq!(g.balance("a").0, 4_960_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    } else {
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
