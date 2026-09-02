package registry

import (
	"sync"
	"sync/atomic"
)

// version_memo.go — memoized parsing of provider binary versions.
//
// The routing scan compares every provider's reported version against the
// capability floors (providerMeetsTraitFloorsLocked) and the pooled-budget
// layout floor (slotBudgetLayoutForVersion → CompareVersions) on every
// request. Parsing a dotted version allocates (strings.Split + a segment
// slice) — ~4% of the fleet-scale scan's allocation volume for what is, in
// practice, a handful of distinct strings across the whole fleet. Each memo
// below maps the RAW input string to its parsed result behind a copy-on-write
// map: reads are one atomic load plus a map lookup with no lock and no
// allocation; inserts (rare — a new version string) rebuild the small map.
//
// Bound: a memo holds at most versionMemoCap entries. Provider versions are
// attacker-supplied at registration, so an unbounded map would let a client
// grow coordinator memory by registering with random strings. When the cap is
// reached the memo is RESET rather than frozen, so a flood of garbage costs a
// rebuild (cheap) instead of permanently disabling caching for the real
// versions, which are re-memoized on their next use.

// versionMemoCap bounds each memo's entry count.
const versionMemoCap = 256

// cowMemo is a bounded, copy-on-write, string-keyed memo. The zero value is
// ready to use.
type cowMemo[V any] struct {
	entries atomic.Pointer[map[string]V]
	mu      sync.Mutex // serializes rebuilds; readers never take it
}

// get returns the memoized value for key, computing and inserting it on a
// miss. Values are shared between callers and must be treated as read-only.
func (m *cowMemo[V]) get(key string, compute func(string) V) V {
	if cur := m.entries.Load(); cur != nil {
		if v, ok := (*cur)[key]; ok {
			return v
		}
	}
	v := compute(key)
	m.mu.Lock()
	defer m.mu.Unlock()
	cur := m.entries.Load()
	var next map[string]V
	if cur == nil || len(*cur) >= versionMemoCap {
		next = make(map[string]V, 8)
	} else {
		if have, ok := (*cur)[key]; ok {
			// Lost the insert race: hand back the shared value, not a duplicate.
			return have
		}
		next = make(map[string]V, len(*cur)+1)
		for k, val := range *cur {
			next[k] = val
		}
	}
	next[key] = v
	m.entries.Store(&next)
	return v
}

// size reports the current entry count (tests).
func (m *cowMemo[V]) size() int {
	if cur := m.entries.Load(); cur != nil {
		return len(*cur)
	}
	return 0
}

// reset drops every entry (tests).
func (m *cowMemo[V]) reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.entries.Store(nil)
}

var (
	// versionSegmentsMemo backs versionSegments (request_traits.go).
	versionSegmentsMemo cowMemo[[]int]
	// slotBudgetLayoutMemo backs slotBudgetLayoutForVersion (pooled_admission.go).
	slotBudgetLayoutMemo cowMemo[slotBudgetLayout]
)
