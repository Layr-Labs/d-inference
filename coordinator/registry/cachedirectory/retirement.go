package cachedirectory

// The caller revokes the generation before clearing the retired directory.
// Old receipt and preparation calls cannot repopulate it.
func (t *Directory[C]) ClearRetired() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.holders, t.attempts = nil, nil
	t.holderOrder, t.attemptOrder = nil, nil
	t.holderOrderByRef, t.attemptOrderByNonce = nil, nil
	t.v2Sequences, t.rejectedV2 = nil, nil
	t.holderCount = 0
}
