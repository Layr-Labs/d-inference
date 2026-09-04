package registry

import (
	"math/bits"
	"sync"
	"sync/atomic"
	"time"
)

// lock_metrics.go — the Registry.mu wait instrument and the scan-frequency
// counters the lock/scan work is judged by.
//
// Registry.mu is a sync.RWMutex whose writer queue is the per-attempt writes
// (the reservation commit plus the outcome recorders): the heartbeat and the
// fleet walks are readers. Under Go's RWMutex a queued writer waits out the
// in-flight reader batch and blocks new readers, so writer wait time IS the
// routing_saturated mechanism — but until now it was invisible (the 2026-08-31
// incident needed goroutine dumps to see 142 writers parked on r.mu.Lock).
// registryMutex records every exclusive acquisition's wait (count, sum, max,
// and fixed log2 buckets for p50/p95/p99) and the number of writers currently
// parked. RLock/RUnlock/Unlock are inherited untouched, so the scan path pays
// nothing; Lock() pays two atomic adds and a clock read (~50 ns) at a few
// hundred acquisitions per second. Nothing here allocates.

// lockWaitBuckets is the number of log2(µs) buckets: bucket 0 holds waits
// under 1 µs, bucket i (i ≥ 1) holds waits in [2^(i-1), 2^i) µs, so bucket 31
// covers waits of 2^30 µs (~18 min) and above.
const lockWaitBuckets = 32

// registryMutex is Registry.mu. It embeds sync.RWMutex so every existing
// r.mu.Lock()/RLock()/Unlock()/RUnlock() call compiles unchanged; only Lock()
// is wrapped. The zero value is ready to use (zero RWMutex + zero atomics), so
// Registry literals in tests remain valid.
type registryMutex struct {
	sync.RWMutex
	// writersWaiting is the number of goroutines parked in Lock() right now.
	writersWaiting atomic.Int32
	// waitNS / waitMaxNS accumulate the wait of every Lock() since the last
	// reset; waitBuckets counts acquisitions by log2(wait µs).
	waitNS      atomic.Int64
	waitMaxNS   atomic.Int64
	waitBuckets [lockWaitBuckets]atomic.Int64
}

// Lock acquires the exclusive lock and records how long the caller waited.
func (m *registryMutex) Lock() {
	m.writersWaiting.Add(1)
	start := time.Now()
	m.RWMutex.Lock()
	wait := time.Since(start)
	m.writersWaiting.Add(-1)
	m.recordWait(wait)
}

func (m *registryMutex) recordWait(wait time.Duration) {
	ns := int64(wait)
	if ns < 0 {
		ns = 0
	}
	m.waitNS.Add(ns)
	for {
		cur := m.waitMaxNS.Load()
		if ns <= cur || m.waitMaxNS.CompareAndSwap(cur, ns) {
			break
		}
	}
	m.waitBuckets[lockWaitBucket(ns/1000)].Add(1)
}

// lockWaitBucket maps a wait in microseconds to its log2 bucket.
func lockWaitBucket(us int64) int {
	if us <= 0 {
		return 0
	}
	b := bits.Len64(uint64(us))
	if b >= lockWaitBuckets {
		return lockWaitBuckets - 1
	}
	return b
}

// lockWaitBucketUpperUS is the (exclusive) upper bound of a bucket in µs; the
// percentile estimates below report it, so they are conservative by at most
// a factor of two while MaxUS is exact.
func lockWaitBucketUpperUS(bucket int) int64 {
	if bucket <= 0 {
		return 0
	}
	return int64(1) << uint(bucket)
}

// LockWaitStats is one window of Registry.mu writer-wait statistics.
type LockWaitStats struct {
	// Count is the number of exclusive acquisitions in the window.
	Count int64
	// MeanUS / MaxUS are the mean and maximum writer wait; P50US / P95US /
	// P99US are bucketed estimates (upper bound of the log2 bucket holding the
	// percentile, clamped to MaxUS).
	MeanUS, MaxUS, P50US, P95US, P99US int64
	// WritersWaiting is the number of writers parked in Lock() at snapshot time.
	WritersWaiting int32
}

// stats reads the window; reset=true also zeroes it (returns-and-resets).
func (m *registryMutex) stats(reset bool) LockWaitStats {
	var buckets [lockWaitBuckets]int64
	var count int64
	for i := range buckets {
		if reset {
			buckets[i] = m.waitBuckets[i].Swap(0)
		} else {
			buckets[i] = m.waitBuckets[i].Load()
		}
		count += buckets[i]
	}
	var sumNS, maxNS int64
	if reset {
		sumNS, maxNS = m.waitNS.Swap(0), m.waitMaxNS.Swap(0)
	} else {
		sumNS, maxNS = m.waitNS.Load(), m.waitMaxNS.Load()
	}
	out := LockWaitStats{
		Count:          count,
		MaxUS:          maxNS / 1000,
		WritersWaiting: m.writersWaiting.Load(),
	}
	if count == 0 {
		return out
	}
	out.MeanUS = sumNS / count / 1000
	percentile := func(p float64) int64 {
		rank := int64(p * float64(count))
		if rank < 1 {
			rank = 1
		}
		var seen int64
		for i, n := range buckets {
			seen += n
			if seen >= rank {
				v := lockWaitBucketUpperUS(i)
				if v > out.MaxUS {
					v = out.MaxUS
				}
				return v
			}
		}
		return out.MaxUS
	}
	out.P50US = percentile(0.50)
	out.P95US = percentile(0.95)
	out.P99US = percentile(0.99)
	return out
}

// LockWaitSnapshot returns the Registry.mu writer-wait window since the
// previous call and resets it. The DogStatsD gauge loop is its one owner
// (registry.mu.* series, every 15 s); everything else reads LockWaitPeek.
func (r *Registry) LockWaitSnapshot() LockWaitStats {
	return r.mu.stats(true)
}

// LockWaitPeek returns the writer-wait window accumulated since the last
// LockWaitSnapshot without resetting it (the fleet sampler reads its p95 from
// here, so the two consumers never starve each other).
func (r *Registry) LockWaitPeek() LockWaitStats {
	return r.mu.stats(false)
}

// scanCounters are the cumulative fleet-walk frequency counters. One atomic
// add per walk (~300 µs of work at fleet scale) is noise; the api layer emits
// deltas on the gauge tick so the walks-per-request ratio is observable.
type scanCounters struct {
	// fleetWalks counts every O(fleet) provider walk: the candidate scan
	// (dispatch, plan refresh, breaker fail-open rescan, shadow rescan) and
	// the capacity preflight.
	fleetWalks atomic.Int64
	// shadowRescans counts the TTFT shadow evaluator's post-commit re-walk.
	shadowRescans atomic.Int64
}

// FleetWalkCount is the cumulative number of full-fleet provider walks.
func (r *Registry) FleetWalkCount() int64 {
	return r.scanStats.fleetWalks.Load()
}

// ShadowRescanCount is the cumulative number of post-commit shadow rescans.
func (r *Registry) ShadowRescanCount() int64 {
	return r.scanStats.shadowRescans.Load()
}
