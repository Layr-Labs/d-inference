package providerversion

// size reports the current entry count (tests).
func (m *cowMemo[V]) size() int {
	if cur := m.entries.Load(); cur != nil {
		return len(*cur)
	}
	return 0
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
