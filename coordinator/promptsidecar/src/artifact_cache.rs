use std::collections::{HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Condvar, Mutex, Weak};

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
    retention: Retention,
}

struct State<T, E> {
    entries: HashMap<String, Entry<T>>,
    order: VecDeque<String>,
    loading: HashMap<String, Arc<Flight<T, E>>>,
}

#[derive(Clone, Copy)]
enum Retention {
    Strong,
    Weak,
}

enum Entry<T> {
    Strong(Arc<T>),
    Weak(Weak<T>),
}

impl<T> Entry<T> {
    fn upgrade(&self) -> Option<Arc<T>> {
        match self {
            Self::Strong(value) => Some(value.clone()),
            Self::Weak(value) => value.upgrade(),
        }
    }
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
        Self::with_retention(capacity, Retention::Strong)
    }

    /// A bounded interner: entries only remember live callers' ownership.
    /// Flights retain their result until waiting callers receive it, but an
    /// idle cache never keeps an otherwise unused value alive.
    pub fn new_weak(capacity: usize) -> Self {
        Self::with_retention(capacity, Retention::Weak)
    }

    fn with_retention(capacity: usize, retention: Retention) -> Self {
        Self {
            state: Mutex::new(State {
                entries: HashMap::new(),
                order: VecDeque::new(),
                loading: HashMap::new(),
            }),
            capacity: capacity.max(1),
            retention,
        }
    }

    pub fn get_or_load(
        &self,
        key: &str,
        loader: impl FnOnce() -> Result<T, E>,
    ) -> Result<(Arc<T>, CacheAccess), CacheFailure<E>> {
        let (flight, owner) = {
            let mut state = self.state.lock().map_err(|_| CacheFailure::Poisoned)?;
            if let Some(value) = state.entries.get(key).and_then(Entry::upgrade) {
                touch(&mut state.order, key);
                return Ok((value, CacheAccess::Warm));
            }
            if state.entries.remove(key).is_some() {
                state.order.retain(|entry| entry != key);
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
                    let entry = match self.retention {
                        Retention::Strong => Entry::Strong(value.clone()),
                        Retention::Weak => Entry::Weak(Arc::downgrade(value)),
                    };
                    state.entries.insert(key.to_owned(), entry);
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
                loaded: state
                    .entries
                    .values()
                    .filter(|entry| entry.upgrade().is_some())
                    .count(),
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
mod tests;
