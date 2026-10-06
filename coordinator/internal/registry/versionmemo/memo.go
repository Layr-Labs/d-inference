// Package versionmemo owns bounded, copy-on-write parsing of provider versions.
package versionmemo

import (
	"strings"
	"sync"
	"sync/atomic"
)

const (
	capacity    = 256
	maxKeyBytes = 64
	maxSegments = 16
)

// Memo retains at most 256 values keyed by strings of at most 64 bytes. A full
// memo keeps existing entries and computes misses without rebuilding or taking
// the writer lock. Keys are cloned so substrings cannot retain oversized input
// buffers. The zero value is ready to use; a Memo must not be copied after use.
type Memo[V any] struct {
	entries atomic.Pointer[map[string]V]
	mu      sync.Mutex
}

// Get returns a cached value and whether it was found, without computing a miss.
// Values are shared between callers and must be treated as read-only.
func (m *Memo[V]) Get(key string) (V, bool) {
	if cur := m.entries.Load(); cur != nil {
		v, ok := (*cur)[key]
		return v, ok
	}
	var zero V
	return zero, false
}

// Load returns the cached value or computes it on a miss. It retains the result
// only when space and key bounds permit and keep (if non-nil) accepts the value.
// Warm reads require one atomic load and one map lookup, with no allocation.
func (m *Memo[V]) Load(key string, compute func(string) V, keep func(V) bool) V {
	if v, ok := m.Get(key); ok {
		return v
	}
	if cur := m.entries.Load(); cur != nil && len(*cur) >= capacity {
		return compute(key)
	}
	v := compute(key)
	if len(key) > maxKeyBytes || (keep != nil && !keep(v)) {
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
			// A competing insert wins; all readers share the retained value.
			return have
		}
		if len(*cur) >= capacity {
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
