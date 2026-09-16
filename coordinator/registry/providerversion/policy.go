package providerversion

// Policy owns the bounded version-interpretation caches used by routing and
// slot-budget compatibility. The zero value is ready for concurrent use.
type Policy struct {
	versionSegmentsMemo  cowMemo[[]int]
	slotBudgetLayoutMemo cowMemo[SlotBudgetLayout]
}

// Memoized reports whether the exact key is retained in each cache. It neither
// parses nor inserts a key, so diagnostics cannot change the cache contents.
func (p *Policy) Memoized(key string) (segments, layout bool) {
	return p.versionSegmentsMemo.has(key), p.slotBudgetLayoutMemo.has(key)
}
