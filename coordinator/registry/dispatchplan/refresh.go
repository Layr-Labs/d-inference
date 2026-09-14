package dispatchplan

// ClaimRefresh consumes the plan's one refresh before copying the attempted
// set. The caller may append its exclusions without another allocation, then
// performs the live scan after this leaf lock has been released.
func (dp *Plan[C]) ClaimRefresh(extraCapacity int) ([]string, bool) {
	dp.mu.Lock()
	if dp.refreshUsed {
		dp.mu.Unlock()
		return nil, false
	}
	dp.refreshUsed = true
	exclude := make([]string, 0, len(dp.attempted)+extraCapacity)
	for id := range dp.attempted {
		exclude = append(exclude, id)
	}
	dp.mu.Unlock()
	return exclude, true
}

// MarkRefreshed binds a fresh plan to the same single-refresh request chain.
func (dp *Plan[C]) MarkRefreshed() {
	dp.mu.Lock()
	dp.refreshUsed = true
	dp.mu.Unlock()
}
