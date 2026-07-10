//! Concurrent MemoryLedger.job_funded_start under parallel mark/settle.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_job_funded_start_readers_during_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
        assert!(g.job_funded_start("j"));
    }

    let led_r = led.clone();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let led = led_r.clone();
            thread::spawn(move || {
                let g = led.lock().unwrap();
                g.job_funded_start("j")
            })
        })
        .collect();

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s".into()), "j", "a", 100_000, "d")
            .unwrap()
    });

    assert!(settle.join().unwrap());
    // funded_start flag remains true after settle (disposition set separately)
    for h in readers {
        assert!(h.join().unwrap());
    }
    assert!(led.lock().unwrap().job_funded_start("j"));
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
