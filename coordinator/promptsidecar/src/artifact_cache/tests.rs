use super::*;
use std::sync::Barrier;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

#[test]
fn concurrent_miss_loads_once() {
    let cache = Arc::new(SingleflightLru::<usize, ()>::new(2));
    let barrier = Arc::new(Barrier::new(16));
    let loads = Arc::new(AtomicUsize::new(0));
    let threads = (0..16)
        .map(|_| {
            let cache = cache.clone();
            let barrier = barrier.clone();
            let loads = loads.clone();
            thread::spawn(move || {
                barrier.wait();
                cache
                    .get_or_load("contract", || {
                        loads.fetch_add(1, Ordering::Relaxed);
                        thread::sleep(Duration::from_millis(30));
                        Ok(7)
                    })
                    .unwrap()
            })
        })
        .collect::<Vec<_>>();

    let accesses = threads
        .into_iter()
        .map(|thread| thread.join().unwrap())
        .map(|(value, access)| {
            assert_eq!(*value, 7);
            access
        })
        .collect::<Vec<_>>();
    assert_eq!(loads.load(Ordering::Relaxed), 1);
    assert_eq!(
        accesses
            .iter()
            .filter(|access| **access == CacheAccess::Cold)
            .count(),
        1
    );
    assert!(accesses.contains(&CacheAccess::Waited));
    assert_eq!(
        cache.stats(),
        CacheStats {
            capacity: 2,
            loaded: 1,
            loading: 0
        }
    );
}

#[test]
fn lru_remains_bounded_and_touch_is_stable() {
    let cache = SingleflightLru::<usize, ()>::new(2);
    cache.get_or_load("a", || Ok(1)).unwrap();
    cache.get_or_load("b", || Ok(2)).unwrap();
    assert_eq!(
        cache.get_or_load("a", || Ok(9)).unwrap().1,
        CacheAccess::Warm
    );
    cache.get_or_load("c", || Ok(3)).unwrap();
    let (reloaded, access) = cache.get_or_load("b", || Ok(4)).unwrap();

    assert_eq!(*reloaded, 4);
    assert_eq!(access, CacheAccess::Cold);
    assert_eq!(cache.stats().loaded, 2);
    assert_eq!(cache.stats().loading, 0);
}

#[test]
fn weak_entries_share_live_owners_without_retaining_idle_values() {
    let cache = SingleflightLru::<usize, ()>::new_weak(2);
    let (a, _) = cache.get_or_load("a", || Ok(1)).unwrap();
    let weak = Arc::downgrade(&a);
    let (shared, access) = cache.get_or_load("a", || panic!("duplicate load")).unwrap();
    assert_eq!(access, CacheAccess::Warm);
    assert!(Arc::ptr_eq(&a, &shared));
    drop(a);
    assert!(weak.upgrade().is_some());
    drop(shared);
    assert!(weak.upgrade().is_none(), "interner retained an idle value");
    assert_eq!(cache.stats().loaded, 0);

    let (a, access) = cache.get_or_load("a", || Ok(2)).unwrap();
    assert_eq!(access, CacheAccess::Cold);
    let (b, _) = cache.get_or_load("b", || Ok(3)).unwrap();
    let (c, _) = cache.get_or_load("c", || Ok(4)).unwrap();
    assert_eq!(cache.state.lock().unwrap().entries.len(), 2);
    assert_eq!(*a, 2, "metadata eviction must not invalidate a live owner");
    drop((a, b, c));
    assert_eq!(cache.stats().loaded, 0);
    assert!(cache.state.lock().unwrap().entries.len() <= 2);
}

#[test]
fn concurrent_weak_miss_constructs_one_shared_owner() {
    let cache = Arc::new(SingleflightLru::<usize, ()>::new_weak(2));
    let barrier = Arc::new(Barrier::new(16));
    let loads = Arc::new(AtomicUsize::new(0));
    let threads = (0..16)
        .map(|_| {
            let (cache, barrier, loads) = (cache.clone(), barrier.clone(), loads.clone());
            thread::spawn(move || {
                barrier.wait();
                cache
                    .get_or_load("tokenizer", || {
                        loads.fetch_add(1, Ordering::Relaxed);
                        thread::sleep(Duration::from_millis(30));
                        Ok(7)
                    })
                    .unwrap()
                    .0
            })
        })
        .collect::<Vec<_>>();
    let owners = threads
        .into_iter()
        .map(|t| t.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(loads.load(Ordering::Relaxed), 1);
    assert!(owners.iter().all(|owner| Arc::ptr_eq(owner, &owners[0])));
    let weak = Arc::downgrade(&owners[0]);
    drop(owners);
    assert!(weak.upgrade().is_none());
    assert_eq!(cache.stats().loading, 0);
}

#[test]
fn concurrent_failed_weak_load_wakes_waiters_and_can_retry() {
    let cache = Arc::new(SingleflightLru::<usize, &str>::new_weak(2));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let owner_cache = cache.clone();
    let owner = thread::spawn(move || {
        owner_cache.get_or_load("bad", || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Err("invalid tokenizer")
        })
    });
    started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    let waiters = (0..8)
        .map(|_| {
            let cache = cache.clone();
            thread::spawn(move || cache.get_or_load("bad", || panic!("duplicate failed load")))
        })
        .collect::<Vec<_>>();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        // Owner + loading table + eight waiters must all hold this same flight
        // before releasing the controlled failure; no timing-only sleep test.
        let attached = Arc::strong_count(cache.state.lock().unwrap().loading.get("bad").unwrap());
        if attached == 10 {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "waiters did not attach"
        );
        thread::sleep(Duration::from_millis(1));
    }
    release_tx.send(()).unwrap();
    for result in
        std::iter::once(owner.join().unwrap()).chain(waiters.into_iter().map(|t| t.join().unwrap()))
    {
        assert!(matches!(result, Err(CacheFailure::Load(error)) if *error == "invalid tokenizer"));
    }
    assert_eq!(cache.stats().loading, 0);
    let (recovered, access) = cache.get_or_load("bad", || Ok(8)).unwrap();
    assert_eq!(access, CacheAccess::Cold);
    assert_eq!(*recovered, 8);
    assert_eq!(
        cache
            .get_or_load("bad", || panic!("retry not cached"))
            .unwrap()
            .1,
        CacheAccess::Warm
    );
}
