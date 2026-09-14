package dispatchplan

// Entries returns copied records for diagnostics. The returned slice never
// aliases the owner's ordering or quote state; Connection stays opaque.
func (dp *Plan[C]) Entries() []Retained[C] {
	if dp == nil {
		return nil
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return append([]Retained[C](nil), dp.entries...)
}
