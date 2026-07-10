//! Concurrent deposit with release/recover/capped 3-way on reserved: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_with_release_recover_capped_on_reserved_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 420_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 110_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rrc_3way", "a", 65_000, 12_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_rel = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_rel.lock().unwrap();
        g.release(OperationKey("rel:j".into()), "j", "a")
            .map(|applied| applied)
            .unwrap_or(false)
    });

    let led_rec = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_rec, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            70_000,
            25_000,
            "capped-dep-rrc-3way",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let released = release.join().unwrap();
    let recovered = recover.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    let wins = (released as u8) + (recovered as u8) + (capped_ok as u8);
    assert_eq!(wins, 1);

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    if capped_ok {
        // Seed 420k + deposit 65k = 485k. Charged 25k → free = 460k
        assert_eq!(g.balance("a").0, 460_000);
        assert_eq!(g.job_disposition("j"), Some("settled"));
    } else {
        // full release → 485k
        assert_eq!(g.balance("a").0, 485_000);
    }
}
