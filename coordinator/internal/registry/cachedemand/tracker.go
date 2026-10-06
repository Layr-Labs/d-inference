// Package cachedemand retains bounded advisory demand, never cache proof.
package cachedemand

import (
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

const (
	// Every match checks its own timestamp. The bounded head sweep only
	// reclaims storage, so stale records behind newer arrivals never match.
	MaxExpiryPerObserve = 1_024
	MaxEntries          = 1_000_000
	// DefaultTTL matches the 30 minutes providers keep a saved prefix, which
	// is also the lifetime the indexes are sized for (SizingTTL).
	DefaultTTL = 30 * time.Minute
	SizingTTL  = 30 * time.Minute
)

type Boundary struct {
	Key    string
	Tokens int
}

type Tracker struct {
	mu           sync.Mutex
	limit        int
	ttl          time.Duration
	index        *cachehistory.Index
	onTouched    func([]string, time.Time)
	capEvictions uint64
}

func New(limit int, ttl time.Duration, index *cachehistory.Index) *Tracker {
	if index == nil {
		index = cachehistory.New()
	}
	return &Tracker{limit: max(1, limit), ttl: ttl, index: index}
}

func (d *Tracker) SetOnTouched(fn func([]string, time.Time)) {
	d.mu.Lock()
	d.onTouched = fn
	d.mu.Unlock()
}

func (d *Tracker) Observe(boundaries []Boundary, now time.Time) (int, string) {
	longest, affinity, touched, onTouched := d.observe(boundaries, now)
	if onTouched != nil && len(touched) > 0 {
		onTouched(touched, now)
	}
	return longest, affinity
}

func (d *Tracker) observe(boundaries []Boundary, now time.Time) (int, string, []string, func([]string, time.Time)) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var touched []string
	for expired := 0; expired < MaxExpiryPerObserve; expired++ {
		first, ok := d.index.Front()
		if !ok || now.Sub(first.Seen) < d.ttl {
			break
		}
		d.index.Delete(first.Key)
	}
	// The deepest matched stride supplies repeat work; a matched ladder rung
	// supplies affinity so conversation growth does not move it each turn.
	longest, deepest, rung, affinity := 0, "", 0, ""
	// Read the old set before inserting: a request cannot match itself.
	for _, boundary := range boundaries {
		entry, ok := d.index.Load(boundary.Key)
		if !ok {
			continue
		}
		// Sampled timestamps need not arrive in lock acquisition order.
		if age := now.Sub(entry.Seen); age < 0 || age >= d.ttl {
			continue
		}
		if boundary.Tokens > longest {
			longest, deepest = boundary.Tokens, boundary.Key
		}
		if boundary.Tokens > rung && AffinityRung(boundary.Tokens) {
			rung, affinity = boundary.Tokens, boundary.Key
		}
	}
	if affinity == "" {
		affinity = deepest
	}
	for _, boundary := range boundaries {
		if boundary.Key == "" {
			continue
		}
		if previous, ok := d.index.Load(boundary.Key); ok && now.Before(previous.Seen) {
			continue
		}
		d.index.Store(cachehistory.Entry{Key: boundary.Key, Seen: now})
		if d.onTouched != nil {
			touched = append(touched, boundary.Key)
		}
		for d.index.Len() > d.limit {
			evicted, _ := d.index.Front()
			// A stale head beyond the sweep budget is an expiry, not a lost repeat.
			if now.Sub(evicted.Seen) < d.ttl {
				d.capEvictions++
			}
			d.index.Delete(evicted.Key)
		}
	}
	return longest, affinity, touched, d.onTouched
}

// Restore caps the timestamp-sorted union, never replacing fresher live demand
// with an older durable row. It returns only valid durable rows still retained.
func (d *Tracker) Restore(records []crs.DemandRecord, now time.Time) []crs.DemandRecord {
	d.mu.Lock()
	defer d.mu.Unlock()
	valid := make([]crs.DemandRecord, 0, len(records))
	merged := make(map[string]time.Time, d.index.Len()+len(records))
	for _, entry := range d.index.Snapshot() {
		merged[entry.Key] = entry.Seen
	}
	for _, rec := range records {
		if rec.Key == "" || now.Sub(rec.SeenAt) >= d.ttl || rec.SeenAt.After(now) {
			continue
		}
		valid = append(valid, rec)
		if seen, ok := merged[rec.Key]; !ok || rec.SeenAt.After(seen) {
			merged[rec.Key] = rec.SeenAt
		}
	}
	all := make([]cachehistory.Entry, 0, len(merged))
	for key, seen := range merged {
		all = append(all, cachehistory.Entry{Key: key, Seen: seen})
	}
	slices.SortFunc(all, func(a, b cachehistory.Entry) int {
		if c := a.Seen.Compare(b.Seen); c != 0 {
			return c
		}
		return strings.Compare(a.Key, b.Key)
	})
	if d.limit > 0 && len(all) > d.limit {
		all = all[len(all)-d.limit:]
	}
	d.index.Reset(all)
	accepted := valid[:0]
	for _, rec := range valid {
		if _, kept := d.index.Load(rec.Key); kept {
			accepted = append(accepted, rec)
		}
	}
	return accepted
}

func (d *Tracker) Clear() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.index.Reset(nil)
}

// Stats includes expired entries not yet reached by the bounded head sweep.
func (d *Tracker) Stats() (entries int, capEvictions uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.index.Len(), d.capEvictions
}
