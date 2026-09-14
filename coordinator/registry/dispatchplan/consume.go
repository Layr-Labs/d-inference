package dispatchplan

// Next advances the cursor by one and marks the entry attempted.
func (dp *Plan[C]) Next() (Retained[C], bool) {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.cursor >= len(dp.entries) {
		return Retained[C]{}, false
	}
	e := dp.entries[dp.cursor]
	dp.cursor++
	dp.attempted[e.View.ProviderID] = struct{}{}
	return e, true
}
