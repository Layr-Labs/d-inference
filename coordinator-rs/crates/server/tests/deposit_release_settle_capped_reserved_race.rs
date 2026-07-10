//! Concurrent deposit with release/settle/capped 3-way on reserved: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_with_release_settle_capped_on_reserved_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 550_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 140_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rel_3way", "a", 95_000, 20_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        g.release(OperationKey("rel:j".into()), "j", "a")
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
            35_000,
            "settle-dep-rel-3way",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            80_000,
            35_000,
            "capped-dep-rel-3way",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let released = release.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    let wins = (released as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1);

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if released {
        // Seed 550k + deposit 95k = 645k; full release
        assert_eq!(g.balance("a").0, 645_000);
    } else {
        // charged 35k → free = 645k - 35k = 610k
        assert_eq!(g.balance("a").0, 610_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    }
}
