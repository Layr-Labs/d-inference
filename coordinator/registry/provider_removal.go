package registry

// DisconnectDuplicatesBySerial disconnects all providers that share the same
// serial number as the given provider, except the given provider itself.
// This prevents multiple WebSocket connections from the same physical machine
// from competing for the same MLX-Swift backend on the host.
func (r *Registry) DisconnectDuplicatesBySerial(keepID string, serial string) {
	if serial == "" {
		return
	}

	var toEvict []string

	r.mu.RLock()
	for id, p := range r.providers {
		if id == keepID {
			continue
		}
		if p.AttestationResult != nil && p.AttestationResult.SerialNumber == serial {
			toEvict = append(toEvict, id)
		}
	}
	r.mu.RUnlock()

	for _, id := range toEvict {
		r.logger.Warn("evicting duplicate provider from same device",
			"evicted_id", id,
			"kept_id", keepID,
			"serial", serial,
		)
		// Disconnect closes the socket itself.
		r.Disconnect(id)
	}
}

// RemoveProviderBySerial reports whether any currently-connected provider
// matches the identity (serial OR session id) and, if force is set, evicts them
// from the in-memory map. The DELETE endpoint calls it first with force=false
// to detect an online box (→409), then after the persisted record is purged it
// may call with force=true to drop a lingering in-memory entry so an evict-race
// can't re-persist. Returns true if a matching provider was connected.
func (r *Registry) RemoveProviderBySerial(serialOrID string, force bool) (online bool) {
	if serialOrID == "" {
		return false
	}

	var matched []string
	r.mu.RLock()
	for id, p := range r.providers {
		match := id == serialOrID
		if !match {
			// AttestationResult is written under p.mu (SetAttestationResult), so
			// read it through the thread-safe accessor — this loop holds only the
			// registry lock, not the per-provider one.
			if ar := p.GetAttestationResult(); ar != nil && ar.SerialNumber == serialOrID {
				match = true
			}
		}
		if match {
			matched = append(matched, id)
			// Presence in the map means a live WebSocket connection; treat it as
			// online regardless of routing status (an untrusted-but-connected box
			// would still re-register and re-persist).
			online = true
		}
	}
	r.mu.RUnlock()

	if force {
		// Disconnect takes r.mu itself — call OUTSIDE the RLock above to avoid a
		// self-deadlock (same pattern as DisconnectDuplicatesBySerial).
		for _, id := range matched {
			r.Disconnect(id)
		}
	}
	return online
}
