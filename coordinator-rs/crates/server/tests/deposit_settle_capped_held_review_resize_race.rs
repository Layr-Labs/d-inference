//! Concurrent deposit while settle_capped vs held-review after resize.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_start_authorized_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_settle_capped_vs_held_review_after_resize() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 950_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 400_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_sch_rz", "a", 120_000, 50_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            180_000,
            65_000,
            "capped-dep-held-rz",
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
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    assert!(capped_ok);
    for h in reviews {
        match h.join().unwrap() {
            RecoveryAction::HeldForReview | RecoveryAction::AlreadyTerminal => {}
            other => panic!("unexpected {other:?}"),
        }
    }

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Seed 950k + deposit 120k = 1.07M. Charged 65k → free = 1.005M
    assert_eq!(g.balance("a").0, 1_005_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
