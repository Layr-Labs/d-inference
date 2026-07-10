//! Concurrent mark_start vs resize_and_authorize: XOR authorize paths.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_vs_resize_authorize_xor() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
    }

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j").is_ok()
    });

    let led_r = led.clone();
    let resize = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 250_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });

    let marked = mark.join().unwrap();
    let resized = resize.join().unwrap();
    assert!(
        marked ^ resized,
        "exactly one of mark_start or resize_authorize must win"
    );

    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.active_job_count(), 1);
    if marked {
        assert_eq!(g.job_reserved_total("j").unwrap().0, 100_000);
        assert_eq!(g.balance("a").0, 4_900_000);
    } else {
        assert_eq!(g.job_reserved_total("j").unwrap().0, 250_000);
        assert_eq!(g.balance("a").0, 4_750_000);
    }
}
