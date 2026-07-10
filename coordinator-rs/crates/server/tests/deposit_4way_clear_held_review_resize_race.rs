//! Concurrent deposit with 4-way clear + held-review after resize: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_4way_clear_held_review_after_resize_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 1_100_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 480_000)
            .unwrap();
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
            "evt_4way_held_rz",
            "a",
            160_000,
            55_000,
        )
        .map(|a| a)
        .unwrap_or(false)
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 85_000, "force-dep-4way-held-rz")
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
            85_000,
            "settle-dep-4way-held-rz",
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
            220_000,
            85_000,
            "capped-dep-4way-held-rz",
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
    // Seed 1.1M + deposit 160k = 1.26M. Charged 85k → free = 1.175M
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.balance("a").0, 1_175_000);
    assert!(matches!(
        g.job_disposition("j"),
        Some("settled") | Some("force_settled")
    ));
}
