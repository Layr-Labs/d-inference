package api

// acquireStorage bounds all shadow session database work, including rejected
// proofs, deferred archive completion, standalone events, and enrollment writes.
// It never waits for the shared pool. Inventory and receipt renewal retain their
// separate worker limits. Nested observations reuse the session's permit.
// Only the serialized session worker may call this method.
func (x *appAttestShadowSession) acquireStorage() (release func(), ok bool) {
	if x.storageSlotHeld {
		return func() {}, true
	}
	x.s.appAttestStorageOnce.Do(func() {
		x.s.appAttestStorageSlots = make(chan struct{}, 4)
	})
	select {
	case x.s.appAttestStorageSlots <- struct{}{}:
		x.storageSlotHeld = true
		return func() {
			x.storageSlotHeld = false
			<-x.s.appAttestStorageSlots
		}, true
	default:
		return nil, false
	}
}
