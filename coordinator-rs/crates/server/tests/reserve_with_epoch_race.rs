//! Concurrent reserve_with_epoch binds fencing epoch atomically (DECISIONS #55).

use darkbloom_coordinator::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_with_epoch_all_bound() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    led.lock().unwrap().credit("a", 50_000_000, 0).unwrap();

    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            let job = format!("j{i}");
            let epoch = 100 + i as u64;
            g.reserve_with_epoch(OperationKey(format!("r{i}")), &job, "a", 100_000, epoch)
                .unwrap();
            g.require_fencing_epoch(&job, epoch).is_ok()
                && matches!(
                    g.require_fencing_epoch(&job, epoch + 1),
                    Err(LedgerError::OwnershipLost)
                )
        }));
    }

    for h in handles {
        assert!(h.join().unwrap());
    }
}
