//! Concurrent deposit with settle/force/capped on reserved: force skips;
//! settle and settle_capped refuse without start_authorized (DECISIONS #153).

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_with_3way_on_reserved_force_skips_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 600_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 180_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_3way_rsv", "a", 90_000, 30_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 45_000, "force-dep-3way-rsv")
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
            "settle-dep-3way-rsv",
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
            100_000,
            45_000,
            "capped-dep-3way-rsv",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    assert!(!forced, "force requires start_authorized");
    assert!(!settled, "settle requires start_authorized (DECISIONS #153)");
    assert!(!capped_ok, "settle_capped requires start_authorized");

    let g = led.lock().unwrap();
    // Seed 600k + deposit 90k - reserved 180k still held = 510k
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.balance("a").0, 510_000);
    assert!(g.job_disposition("j").is_none());
}
