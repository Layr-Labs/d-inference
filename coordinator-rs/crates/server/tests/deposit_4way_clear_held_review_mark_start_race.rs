//! Concurrent deposit with 4-way clear + held-review after mark_start: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_4way_clear_held_review_after_mark_start_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 900_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 280_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(
            &mut ib,
            &mut g,
            "stripe",
            "evt_4way_held_ms",
            "a",
            130_000,
            45_000,
        )
        .map(|a| a)
        .unwrap_or(false)
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 70_000, "force-dep-4way-held-ms")
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
            70_000,
            "settle-dep-4way-held-ms",
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
            180_000,
            70_000,
            "capped-dep-4way-held-ms",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        reviews.push(thread::spawn(move || {
            recover_start_authorized_held(&led, "j").unwrap()
        }));
    }

    let deposited = deposit.join().unwrap();
    let forced = force.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    let wins = (forced as u8) + (settled as u8) + (capped_ok as u8);
    assert_eq!(wins, 1);

    for h in reviews {
        match h.join().unwrap() {
            RecoveryAction::HeldForReview | RecoveryAction::AlreadyTerminal => {}
            other => panic!("unexpected {other:?}"),
        }
    }

    let g = led.lock().unwrap();
    // Seed 900k + deposit 130k = 1.03M. Charged 70k → free = 960k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.balance("a").0, 960_000);
    assert!(matches!(
        g.job_disposition("j"),
        Some("settled") | Some("force_settled")
    ));
}
