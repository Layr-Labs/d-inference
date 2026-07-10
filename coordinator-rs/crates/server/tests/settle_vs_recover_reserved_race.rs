//! Concurrent settle vs recover_undispatched on reserved (not authorized) job: XOR.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_vs_recover_on_reserved_only_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 200_000)
            .unwrap();
        // Not start_authorized — settle should Conflict (no funded start required
        // for settle in MemoryLedger — settle works on any active reserved job).
        // recover_undispatched can release.
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            50_000,
            "d-rsv",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_r = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_r, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let settled = settle.join().unwrap();
    let released = recover.join().unwrap();
    assert!(
        settled ^ released,
        "exactly one of settle or recover-release must win"
    );

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if settled {
        // charged 50k of 200k → refund 150k → bal = 5M - 200k + 150k = 4.95M
        assert_eq!(g.balance("a").0, 4_950_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    } else {
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
