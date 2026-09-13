package registry

import (
	"strings"
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
// Bounds. Provider versions are attacker-supplied at registration, so the
// memos are bounded in BOTH dimensions:
//
//   - count: at most versionMemoCap entries; a full memo keeps its existing
//     entries and computes misses without inserting or taking the writer lock.
//     A diverse working set therefore cannot flush hot versions or repeatedly
//     rebuild the map; later versions still parse correctly without caching;
//   - bytes: a key longer than maxMemoizedVersionLen, or a parse with more
//     than maxMemoizedVersionSegments segments, is computed but NEVER inserted
//     (a valid "1.0.0+<multi-MiB metadata>" inside the frame limit could
//     otherwise pin megabytes per entry). The worst case is therefore
//     versionMemoCap × (64-byte key + 16-segment slice) ≈ tens of KiB. Keys
//     are cloned on insertion so a short normalized core cannot keep the
//     backing allocation of an oversized version suffix alive.
//
// The layout memo additionally keys on the NORMALIZED numeric core
// ("1.0.0" for "v1.0.0-rc1+meta"), so suffix variants of one version share an
// entry (pooled_admission.go).

const (
	// versionMemoCap bounds each memo's entry count.
	versionMemoCap = 256
	// maxMemoizedVersionLen bounds the key bytes retained per entry. Real
	// versions are ~6-12 bytes; 64 leaves room for a short prerelease tag.
	maxMemoizedVersionLen = 64
	// maxMemoizedVersionSegments bounds the parsed slice retained per entry.
	maxMemoizedVersionSegments = 16
)

// cowMemo is a bounded, copy-on-write, string-keyed memo. The zero value is
// ready to use.
type cowMemo[V any] struct {
	entries atomic.Pointer[map[string]V]
	mu      sync.Mutex // serializes rebuilds; readers never take it
}

// get returns the memoized value for key, computing and inserting it on a
// miss. Values are shared between callers and must be treated as read-only.
func (m *cowMemo[V]) get(key string, compute func(string) V) V {
	return m.getBounded(key, compute, nil)
}

// getBounded is get with an admission predicate: on a miss the value is
// always computed and returned, but only inserted when keep (if non-nil)
// accepts it and the key is no longer than maxMemoizedVersionLen. Oversized
// inputs therefore cost a parse per call and retain nothing.
func (m *cowMemo[V]) getBounded(key string, compute func(string) V, keep func(V) bool) V {
	if cur := m.entries.Load(); cur != nil {
		if v, ok := (*cur)[key]; ok {
			return v
		}
		if len(*cur) >= versionMemoCap {
			return compute(key)
		}
	}
	v := compute(key)
	if len(key) > maxMemoizedVersionLen || (keep != nil && !keep(v)) {
		return v
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	cur := m.entries.Load()
	var next map[string]V
	if cur == nil {
		next = make(map[string]V, 8)
	} else {
		if have, ok := (*cur)[key]; ok {
			// Lost the insert race: hand back the shared value, not a duplicate.
			return have
		}
		if len(*cur) >= versionMemoCap {
			return v
		}
		next = make(map[string]V, len(*cur)+1)
		for k, val := range *cur {
			next[k] = val
		}
	}
	next[strings.Clone(key)] = v
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

// has reports whether key is currently memoized (tests).
func (m *cowMemo[V]) has(key string) bool {
	if cur := m.entries.Load(); cur != nil {
		_, ok := (*cur)[key]
		return ok
	}
	return false
}

// maxKeyLen returns the longest memoized key in bytes (tests).
func (m *cowMemo[V]) maxKeyLen() int {
	longest := 0
	if cur := m.entries.Load(); cur != nil {
		for k := range *cur {
			if len(k) > longest {
				longest = len(k)
			}
		}
	}
	return longest
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
