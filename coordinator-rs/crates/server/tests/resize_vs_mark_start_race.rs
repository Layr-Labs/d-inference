//! Concurrent resize_and_authorize vs mark_start_authorized: exactly one funds start.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_authorize_vs_mark_start_exactly_one_funds() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let led_r = led.clone();
    let resize = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 1_200_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });
    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j", "a").is_ok()
    });

    let resized = resize.join().unwrap();
    let marked = mark.join().unwrap();
    assert!(
        resized ^ marked,
        "exactly one must fund start; resized={resized} marked={marked}"
    );
    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.held_start_authorized_count(), 1);
    if resized {
        assert_eq!(g.job_reserved_total("j").unwrap().0, 1_200_000);
        assert_eq!(g.balance("a").0, 8_800_000);
    } else {
        assert_eq!(g.job_reserved_total("j").unwrap().0, 1_000_000);
        assert_eq!(g.balance("a").0, 9_000_000);
    }
}
