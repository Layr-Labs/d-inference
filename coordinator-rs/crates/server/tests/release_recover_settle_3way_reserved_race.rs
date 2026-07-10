//! Concurrent release vs recover vs settle on reserved: exactly one clear.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_recover_settle_on_reserved_exactly_one() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 170_000)
            .unwrap();
    }

    let led_rel = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_rel.lock().unwrap();
        match g.release(OperationKey("rel:j".into()), "j", "a") {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_rec = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_rec, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            45_000,
            "settle-rel-rec-3way",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let released = release.join().unwrap();
    let recovered = recover.join().unwrap();
    let settled = settle.join().unwrap();
    let wins = (released as u8) + (recovered as u8) + (settled as u8);
    assert_eq!(wins, 1, "exactly one clear path");

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if settled {
        // charged 45k of 170k → refund 125k → bal = 5M - 170k + 125k = 4.955M
        assert_eq!(g.balance("a").0, 4_955_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    } else {
        assert_eq!(g.balance("a").0, 5_000_000);
    }
}
