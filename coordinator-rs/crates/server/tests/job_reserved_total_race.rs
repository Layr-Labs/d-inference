//! Concurrent MemoryLedger.job_reserved_total under parallel settle.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_job_reserved_total_stable_until_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert_eq!(g.job_reserved_total("j").unwrap().0, 1_000_000);
    }

    let led_r = led.clone();
    let readers: Vec<_> = (0..4)
        .map(|_| {
            let led = led_r.clone();
            thread::spawn(move || {
                let g = led.lock().unwrap();
                g.job_reserved_total("j").map(|m| m.0)
            })
        })
        .collect();

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 400_000, "d")
            .unwrap()
    });

    assert!(settle.join().unwrap());
    for h in readers {
        let v = h.join().unwrap();
        // Readers may see Some(1M) before settle or still Some after
        // (job record retained with disposition).
        assert!(v.is_none() || v == Some(1_000_000));
    }
    // After settle, reserved total still readable on disposed job.
    assert_eq!(
        led.lock().unwrap().job_reserved_total("j").unwrap().0,
        1_000_000
    );
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
