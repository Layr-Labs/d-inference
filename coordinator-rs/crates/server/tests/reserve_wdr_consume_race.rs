//! Concurrent reserve consuming withdrawable when non-wdr exhausted.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_consumes_withdrawable_when_needed() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    // bal=2M, wdr=2M (all withdrawable)
    led.lock()
        .unwrap()
        .credit("a", 2_000_000, 2_000_000)
        .unwrap();

    let mut handles = Vec::new();
    for i in 0..4 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.reserve(
                OperationKey(format!("r-{i}")),
                &format!("j-{i}"),
                "a",
                800_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    // 2M / 800k = 2 successes
    assert_eq!(wins, 2);
    let (bal, wdr) = led.lock().unwrap().balance("a");
    assert_eq!(bal, 400_000);
    assert_eq!(wdr, 400_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 2);
}
