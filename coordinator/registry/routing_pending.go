package registry

// fillSnapshotPendingAndPool populates snap's reconstructed pooled budget and
// its coordinator-pending aggregates — the per-model filtered pair
// (pendingForModel / pendingMaxTokens) and the all-models totals in token and,
// when normalizable, byte units. Byte normalization uses each resident model's
// reported KVBytesPerToken and the same bounded conservative default as
// incoming/capacity math for a cold model with no resident slot. Only a legacy
// pool that cannot be reconstructed in bytes leaves pendingBytesKnown false.
// Shared by the dispatch
// snapshot (snapshotProviderLockedEx) and the queue preflight
// (QuickCapacityCheck…) so the two admission paths cannot drift. Caller holds
// p.mu.
func fillSnapshotPendingAndPool(snap *routingSnapshot, p *Provider, model string) {
	snap.PendingPrefillKnown = true
	if p.BackendCapacity != nil {
		snap.PooledTokenBudget = providerPooledTokenBudgetForVersion(
			p.BackendCapacity.Slots, p.Version)
	}
	bytesKnown := snap.PooledTokenBudget.ByteMode()
	for _, pr := range p.pendingReqs {
		tokens := pendingTokenBudget(pr)
		snap.PendingMaxTokensAllModels += tokens
		if bytesKnown {
			rate := resolvedPooledKVBytesPerToken(&snap.PooledTokenBudget, snap.PooledTokenBudget.KVRateFor(pr.Model))
			snap.PendingMaxBytesAllModels = addPooledKVByteCharge(snap.PendingMaxBytesAllModels, int64(tokens), rate)
		}
		if pr.Model != model {
			continue
		}
		snap.PendingForModel++
		snap.PendingMaxTokens += tokens
		if !pr.ContentCommittedSafe() {
			if pr.EstimatedPromptTokens > 0 && !pr.CacheRoutingParticipates() {
				snap.PendingPrefillTokens += float64(pr.EstimatedPromptTokens)
			} else {
				snap.PendingPrefillUnknown++
			}
		}
	}
	snap.PendingBytesKnown = bytesKnown
}

func pendingTokenBudget(pr *PendingRequest) int {
	if pr == nil {
		return 0
	}
	prompt := pr.EstimatedPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok := pr.RequestedMaxTokens
	if maxTok <= 0 {
		maxTok = defaultRequestedMaxTokens
	}
	return prompt + maxTok
}
