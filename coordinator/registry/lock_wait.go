package registry

import "time"

// SetLockWaitObserver registers an optional observer for request-path write
// acquisitions of the registry lock: it receives the call site and how long
// the acquisition waited. The api layer turns it into the
// registry.mu.write_wait_ms histogram tagged by site, which measures the
// write-lock convoy directly instead of inferring it from goroutine dumps.
// The observer runs after the lock is released (see writeHold). Set once at
// startup; nil clears it. Thread-safe.
func (r *Registry) SetLockWaitObserver(fn func(site string, wait time.Duration)) {
	if fn == nil {
		r.lockWaitObserver.Store(nil)
		return
	}
	r.lockWaitObserver.Store(&fn)
}

// writeHold is an acquired request-path write lock. unlock releases r.mu
// and only then reports the acquisition wait to the observer, so the
// observer (a DogStatsD histogram in the api layer) never runs inside the
// critical section of the busiest lock in the process.
type writeHold struct {
	r    *Registry
	site string
	wait time.Duration
	obs  *func(site string, wait time.Duration)
}

// lockWrite measures the remaining global write acquisitions, including
// reservation commits in global compatibility mode. Per-identity recorders
// use lockGate and its separate observer. With no observer registered it costs one atomic load; with one,
// it measures the acquisition wait for the returned hold to report on unlock.
func (r *Registry) lockWrite(site string) writeHold {
	obs := r.lockWaitObserver.Load()
	if obs == nil {
		r.mu.Lock()
		return writeHold{r: r}
	}
	start := time.Now()
	r.mu.Lock()
	return writeHold{r: r, site: site, wait: time.Since(start), obs: obs}
}

// unlock releases the write lock and reports the wait recorded by lockWrite.
func (h writeHold) unlock() {
	h.r.mu.Unlock()
	if h.obs != nil {
		(*h.obs)(h.site, h.wait)
	}
}
