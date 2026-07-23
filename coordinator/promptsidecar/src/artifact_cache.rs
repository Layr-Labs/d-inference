use std::collections::{HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Condvar, Mutex};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheAccess {
    Cold,
    Warm,
    Waited,
}

#[derive(Debug)]
pub enum CacheFailure<E> {
    Load(Arc<E>),
    Poisoned,
}

impl<E> Clone for CacheFailure<E> {
    fn clone(&self) -> Self {
        match self {
            Self::Load(error) => Self::Load(error.clone()),
            Self::Poisoned => Self::Poisoned,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheStats {
    pub capacity: usize,
    pub loaded: usize,
    pub loading: usize,
}

/// A bounded LRU whose misses are singleflight per key.
///
/// The cache mutex is never held while the loader performs file IO, hashing, or
/// tokenizer construction. Concurrent callers for the same key wait on a
/// small per-key condition variable and receive the exact same result. Loads
/// for distinct keys may proceed concurrently, subject to the planner's outer
/// worker bound.
pub struct SingleflightLru<T, E> {
    state: Mutex<State<T, E>>,
    capacity: usize,
}

struct State<T, E> {
    entries: HashMap<String, Arc<T>>,
    order: VecDeque<String>,
    loading: HashMap<String, Arc<Flight<T, E>>>,
}

struct Flight<T, E> {
    result: Mutex<Option<Result<Arc<T>, CacheFailure<E>>>>,
    ready: Condvar,
}

impl<T, E> Flight<T, E> {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
            ready: Condvar::new(),
        }
    }

    fn complete(&self, result: Result<Arc<T>, CacheFailure<E>>) {
        if let Ok(mut slot) = self.result.lock() {
            *slot = Some(result);
            self.ready.notify_all();
        }
    }

    fn wait(&self) -> Result<Arc<T>, CacheFailure<E>> {
        let mut result = self.result.lock().map_err(|_| CacheFailure::Poisoned)?;
        loop {
            if let Some(result) = result.as_ref() {
                return result.clone();
            }
            result = self
                .ready
                .wait(result)
                .map_err(|_| CacheFailure::Poisoned)?;
        }
    }
}

impl<T, E> SingleflightLru<T, E> {
    pub fn new(capacity: usize) -> Self {
        Self {
            state: Mutex::new(State {
                entries: HashMap::new(),
                order: VecDeque::new(),
                loading: HashMap::new(),
            }),
            capacity: capacity.max(1),
        }
    }

    pub fn get_or_load(
        &self,
        key: &str,
        loader: impl FnOnce() -> Result<T, E>,
    ) -> Result<(Arc<T>, CacheAccess), CacheFailure<E>> {
        let (flight, owner) = {
            let mut state = self.state.lock().map_err(|_| CacheFailure::Poisoned)?;
            if let Some(value) = state.entries.get(key).cloned() {
                touch(&mut state.order, key);
                return Ok((value, CacheAccess::Warm));
            }
            if let Some(flight) = state.loading.get(key) {
                (flight.clone(), false)
            } else {
                let flight = Arc::new(Flight::new());
                state.loading.insert(key.to_owned(), flight.clone());
                (flight, true)
            }
        };

        if !owner {
            return flight.wait().map(|value| (value, CacheAccess::Waited));
        }

        let loaded = match catch_unwind(AssertUnwindSafe(loader)) {
            Ok(Ok(value)) => Ok(Arc::new(value)),
            Ok(Err(error)) => Err(CacheFailure::Load(Arc::new(error))),
            Err(_) => Err(CacheFailure::Poisoned),
        };
        // Always complete the flight, including if the cache mutex was
        // poisoned after the loader returned. Otherwise callers already
        // waiting on this key could remain blocked forever.
        let published = match self.state.lock() {
            Ok(mut state) => {
                if let Ok(value) = &loaded {
                    while state.entries.len() >= self.capacity {
                        if let Some(oldest) = state.order.pop_front() {
                            state.entries.remove(&oldest);
                        }
                    }
                    state.entries.insert(key.to_owned(), value.clone());
                    touch(&mut state.order, key);
                }
                state.loading.remove(key);
                loaded.clone()
            }
            Err(_) => Err(CacheFailure::Poisoned),
        };
        flight.complete(published.clone());
        published.map(|value| (value, CacheAccess::Cold))
    }

    pub fn stats(&self) -> CacheStats {
        self.state
            .lock()
            .map(|state| CacheStats {
                capacity: self.capacity,
                loaded: state.entries.len(),
                loading: state.loading.len(),
            })
            .unwrap_or(CacheStats {
                capacity: self.capacity,
                loaded: 0,
                loading: 0,
            })
    }
}

fn touch(order: &mut VecDeque<String>, key: &str) {
    if let Some(index) = order.iter().position(|value| value == key) {
        order.remove(index);
    }
    order.push_back(key.to_owned());
}

#[cfg(test)]
mod tests {
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
}
