//! Concurrent force_settle_held vs recover_start_authorized_held.
//! Classification never moves money; force_settle clears the hold.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{
    force_settle_held, recover_start_authorized_held, RecoveryAction,
};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_and_held_review_never_moves_money_twice() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 400_000, "force-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_h = led.clone();
    let review = thread::spawn(move || recover_start_authorized_held(&led_h, "j").unwrap());

    let forced = force.join().unwrap();
    let reviewed = review.join().unwrap();
    assert!(forced, "force_settle must clear the hold");
    assert!(
        matches!(
            reviewed,
            RecoveryAction::HeldForReview | RecoveryAction::AlreadyTerminal
        ),
        "held review is classify-only; got {reviewed:?}"
    );
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.balance("a").0, 9_600_000);
}
