package cachedirectory

func (t *Directory[C]) Disconnect(providerID string, reason RemovalReason) {
	t.InvalidateProviderEvidence(providerID, reason, false)
}

func (t *Directory[C]) InvalidateProviderEvidence(providerID string, reason RemovalReason, preserveFences bool) {
	if t == nil || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, holders := range t.holders {
		if _, exists := holders[providerID]; exists {
			t.removeHolderLocked(key, providerID, reason)
		}
	}
	for nonce, attempt := range t.attempts {
		if attempt.ProviderID == providerID {
			t.removeAttemptLocked(nonce)
		}
	}
	for key := range t.v2Sequences {
		if key.ProviderID == providerID {
			delete(t.v2Sequences, key)
		}
	}
	for key := range t.rejectedV2 {
		if !preserveFences && key.ProviderID == providerID {
			delete(t.rejectedV2, key)
		}
	}
}

func (t *Directory[C]) InvalidateProviderModel(providerID, modelID string, reason RemovalReason) {
	t.InvalidateProviderModels(providerID, map[string]RemovalReason{modelID: reason})
}

// Scan each index once even when a heartbeat changes several models. Keep
// exact-capability proof fences: an unrelated update cannot reset quarantine.
func (t *Directory[C]) InvalidateProviderModels(providerID string, models map[string]RemovalReason) {
	if t == nil || providerID == "" || len(models) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, holders := range t.holders {
		if holder, ok := holders[providerID]; ok {
			if reason, changed := models[holder.ModelID]; changed {
				t.removeHolderLocked(key, providerID, reason)
			}
		}
	}
	for nonce, attempt := range t.attempts {
		if _, changed := models[attempt.Model]; attempt.ProviderID == providerID && changed {
			t.removeAttemptLocked(nonce)
		}
	}
	for key := range t.v2Sequences {
		if _, changed := models[key.ModelID]; key.ProviderID == providerID && changed {
			delete(t.v2Sequences, key)
		}
	}
}
